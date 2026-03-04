#!/bin/bash
# =============================================================================
# Script   : java_check.sh
# Purpose  : Verify JAVA_HOME (FMW-JDK vs system JDK), Java version,
#            running WLS JVM settings, and Log4j CVE scan
# Call     : ./java_check.sh
# Requires : java, ps, unzip (log4j JAR inspection), awk, grep, readlink
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# Ref Heap : https://docs.oracle.com/middleware/1221/formsandreports/use-reports/pbr_conf013.htm
# Ref Log4j: https://logging.apache.org/log4j/2.x/security.html
#            CVE-2021-44228 / CVE-2021-45046 / CVE-2021-45105 / CVE-2021-44832
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CONF="$ROOT_DIR/environment.conf"

# Load central library
LIB="$ROOT_DIR/00-Setup/IHateWeblogic_lib.sh"
if [ ! -f "$LIB" ]; then
    printf "\033[31mERROR\033[0m Cannot find IHateWeblogic_lib.sh: %s\n" "$LIB" >&2
    exit 2
fi
# shellcheck source=00-Setup/IHateWeblogic_lib.sh
source "$LIB"

# Validate environment.conf
check_env_conf "$ENV_CONF" || exit 2
source "$ENV_CONF"

# Initialize log file
init_log

# =============================================================================
# Helper: compare version strings (x.y.z)
# Returns 0 if $1 < $2, 1 otherwise
# =============================================================================
_version_lt() {
    local a="$1" b="$2"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$a" ] && [ "$a" != "$b" ]
}

# =============================================================================
# Helper: classify log4j version
# Returns: 0=safe(>=2.17.1), 1=vulnerable(2.x<2.17.1), 2=EOL(1.x), 3=unknown
# =============================================================================
_classify_log4j() {
    local ver="$1"
    local major
    major="$(echo "$ver" | cut -d. -f1)"

    case "$major" in
        1)  return 2 ;;   # log4j 1.x – EOL, CVE-2019-17571 etc.
        2)  ;;            # log4j 2.x – check minor/patch
        "")  return 3 ;;  # empty version
        *)   return 0 ;;  # unknown major, assume safe
    esac

    # log4j 2.x: safe if >= 2.17.1
    if _version_lt "$ver" "2.17.1"; then
        return 1   # vulnerable
    else
        return 0   # safe
    fi
}

# =============================================================================
# Helper: extract log4j version from JAR
# Tries: (1) filename, (2) MANIFEST.MF, (3) pom.properties
# =============================================================================
_extract_log4j_version() {
    local jar="$1"
    local ver=""

    # 1. Filename: log4j-core-2.17.1.jar or log4j-2.17.1.jar
    ver="$(basename "$jar" .jar | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    [ -n "$ver" ] && { printf "%s" "$ver"; return; }

    # 2. MANIFEST.MF
    if command -v unzip >/dev/null 2>&1; then
        ver="$(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null \
            | grep -i 'Implementation-Version\|Bundle-Version' \
            | head -1 | cut -d: -f2 | tr -d ' \r\n')"
        [ -n "$ver" ] && { printf "%s" "$ver"; return; }

        # 3. pom.properties (log4j-core typically has this)
        ver="$(unzip -p "$jar" 'META-INF/maven/org.apache.logging.log4j/*/pom.properties' 2>/dev/null \
            | grep '^version=' | head -1 | cut -d= -f2 | tr -d ' \r\n')"
        [ -n "$ver" ] && { printf "%s" "$ver"; return; }
    fi

    printf ""
}

# =============================================================================
# Banner
# =============================================================================
printLine
printf "\n\033[1mIHateWeblogic – Java & JVM Check\033[0m\n"
printf "Host    : %s\n" "$(_get_hostname)"
printf "Date    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Log     : %s\n\n" "$LOG_FILE"

# Global: resolved java binary path (used across sections)
JAVA_REAL=""

# =============================================================================
# Section 1: JAVA_HOME – FMW-JDK vs. System-JDK
# =============================================================================
section "JAVA_HOME – FMW-JDK vs. System-JDK"

if [ -z "${JAVA_HOME:-}" ]; then
    fail "JAVA_HOME is not set"
else
    printList "JAVA_HOME" 32 "$JAVA_HOME"

    # Is JAVA_HOME under FMW_HOME?
    if [[ "$JAVA_HOME" == "${FMW_HOME}"* ]]; then
        ok "JAVA_HOME is under FMW_HOME – FMW-bundled JDK in use"
    else
        warn "JAVA_HOME is NOT under FMW_HOME – external or system JDK detected"
        info "  FMW_HOME  : $FMW_HOME"
        info "  JAVA_HOME : $JAVA_HOME"
        info "  Oracle FMW should use its bundled JDK to avoid compatibility issues"
    fi

    # Resolve java binary
    JAVA_BIN="$JAVA_HOME/bin/java"
    if [ ! -x "$JAVA_BIN" ]; then
        fail "java binary not found or not executable: $JAVA_BIN"
    else
        JAVA_REAL="$(readlink -f "$JAVA_BIN" 2>/dev/null || echo "$JAVA_BIN")"
        printList "java binary" 32 "$JAVA_BIN"
        [ "$JAVA_REAL" != "$JAVA_BIN" ] && \
            printList "  → resolves to" 32 "$JAVA_REAL"

        # Compare with PATH java
        PATH_JAVA="$(command -v java 2>/dev/null || true)"
        if [ -n "$PATH_JAVA" ]; then
            PATH_JAVA_REAL="$(readlink -f "$PATH_JAVA" 2>/dev/null || echo "$PATH_JAVA")"
            printList "PATH java" 32 "$PATH_JAVA"
            if [ "$PATH_JAVA_REAL" = "$JAVA_REAL" ]; then
                ok "PATH java matches JAVA_HOME java"
            else
                warn "PATH java differs from JAVA_HOME java"
                info "  PATH java : $PATH_JAVA_REAL"
                info "  JAVA_HOME : $JAVA_REAL"
                info "  Sourcing setDomainEnv.sh will override PATH – verify startup scripts"
            fi
        else
            warn "java not found in PATH"
        fi
    fi

    # Read $JAVA_HOME/release for vendor/version metadata
    JAVA_RELEASE="$JAVA_HOME/release"
    if [ -f "$JAVA_RELEASE" ]; then
        printf "\n"
        info "Contents of $JAVA_RELEASE:"
        while IFS='=' read -r key val; do
            [ -z "$key" ] && continue
            val="${val//\"/}"
            printList "  $key" 32 "$val"
        done < "$JAVA_RELEASE"
    fi
fi

# =============================================================================
# Section 2: Java Version & Vendor
# =============================================================================
section "Java Version & Vendor"

JAVA_MAJOR=0
JAVA_VER=""

if [ -x "${JAVA_HOME:-}/bin/java" ]; then
    JAVA_VER_OUT="$("$JAVA_HOME/bin/java" -version 2>&1)"
    JAVA_VER_LINE="$(echo "$JAVA_VER_OUT" | head -1)"

    # Extract quoted version string: java version "1.8.0_261" or java version "11.0.12"
    JAVA_VER="$(echo "$JAVA_VER_LINE" | awk -F'"' '{print $2}')"
    printList "Version string" 32 "$JAVA_VER"

    # Determine major version
    if [[ "$JAVA_VER" == 1.* ]]; then
        JAVA_MAJOR="$(echo "$JAVA_VER" | cut -d. -f2)"   # 1.8.x → 8
    else
        JAVA_MAJOR="$(echo "$JAVA_VER" | cut -d. -f1)"   # 11.x.y → 11
    fi
    printList "Major version" 32 "$JAVA_MAJOR"

    # Version assessment for Oracle Forms/Reports 12c / 14c
    # Ref: Oracle FMW 14.1.2 is certified with JDK 8 and JDK 11
    case "${JAVA_MAJOR}" in
        8)   ok   "Java 8 – certified for Oracle Forms/Reports 12c and 14c" ;;
        11)  ok   "Java 11 – certified for Oracle Forms 14c" ;;
        17)  warn "Java 17 – verify certification for your FMW version at support.oracle.com" ;;
        *)
            if [ "${JAVA_MAJOR}" -lt 8 ] 2>/dev/null; then
                fail "Java ${JAVA_MAJOR} – below minimum (JDK 8). FMW will not start."
            else
                warn "Java ${JAVA_MAJOR} – verify at support.oracle.com → Certification Matrix"
            fi
            ;;
    esac

    # Vendor check
    if echo "$JAVA_VER_OUT" | grep -qi "HotSpot"; then
        ok "Vendor: Oracle JDK (HotSpot VM)"
    elif echo "$JAVA_VER_OUT" | grep -qi "OpenJDK"; then
        warn "Vendor: OpenJDK – Oracle FMW is certified with Oracle JDK, not OpenJDK"
        info "  Reference: support.oracle.com → Certification Matrix"
    else
        info "Vendor info: $(echo "$JAVA_VER_OUT" | grep -i 'Runtime\|VM' | head -1 | xargs)"
    fi
else
    fail "Cannot execute java – JAVA_HOME not set or binary missing"
fi

# =============================================================================
# Section 3: Running WLS Processes – Java at Runtime
# =============================================================================
section "Running WLS Processes – Java at Runtime"

# Read full cmdline from /proc for reliable untruncated output
_get_proc_cmdline() {
    local pid="$1"
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
    else
        ps -p "$pid" -o args= 2>/dev/null
    fi
}

WLS_PIDS="$(ps -eo pid= -o args= 2>/dev/null \
    | grep -E 'weblogic\.Server' | grep -v grep \
    | awk '{print $1}')"

if [ -z "$WLS_PIDS" ]; then
    info "No running WebLogic Server JVM processes detected"
    info "(Start AdminServer / Managed Servers first for runtime JVM analysis)"
else
    for pid in $WLS_PIDS; do
        proc_args="$(_get_proc_cmdline "$pid")"

        # Extract java binary (first token of cmdline)
        proc_java="$(echo "$proc_args" | awk '{print $1}')"
        proc_java_real="$(readlink -f "$proc_java" 2>/dev/null || echo "$proc_java")"

        # Server name from -Dweblogic.Name=
        server_name="$(echo "$proc_args" \
            | grep -oE '\-Dweblogic\.Name=[^ ]+' | cut -d= -f2 | head -1)"
        server_name="${server_name:-UnknownServer}"

        printf "\n"
        printList "Server" 32 "$server_name (PID $pid)"
        printList "  java binary" 32 "$proc_java_real"

        # Compare runtime java with JAVA_HOME
        if [ -n "$JAVA_REAL" ] && [ "$proc_java_real" = "$JAVA_REAL" ]; then
            ok "  Runtime java matches JAVA_HOME"
        elif [ -n "$JAVA_REAL" ]; then
            warn "  Runtime java differs from JAVA_HOME!"
            info "    JAVA_HOME : $JAVA_REAL"
            info "    Process   : $proc_java_real"
        fi

        # Extract heap settings from running process
        proc_xms="$(echo "$proc_args" | grep -oE '\-Xms[0-9]+[mMgGkK]' | head -1)"
        proc_xmx="$(echo "$proc_args" | grep -oE '\-Xmx[0-9]+[mMgGkK]' | head -1)"
        proc_gc="$(echo "$proc_args"  | grep -oE '\-XX:\+Use[A-Za-z]+GC' | head -1)"

        [ -n "$proc_xms" ] && printList "  -Xms (runtime)" 32 "$proc_xms" || \
            info "  -Xms not set in process args (JVM default)"
        [ -n "$proc_xmx" ] && printList "  -Xmx (runtime)" 32 "$proc_xmx" || \
            info "  -Xmx not set in process args (JVM default)"
        [ -n "$proc_gc"  ] && printList "  GC collector" 32 "$proc_gc"
    done
fi

# =============================================================================
# Section 4: setDomainEnv.sh – JVM Memory Configuration
# =============================================================================
section "JVM Memory Settings in setDomainEnv.sh"

# Reference values from Oracle documentation
# Src: https://docs.oracle.com/middleware/1221/formsandreports/use-reports/pbr_conf013.htm
info "Oracle documentation reference values for WLS_REPORTS:"
info "  Default example  : -Xms256m  -Xmx512m"
info "  Increased example: -Xms512m  -Xmx1024m"
info "Practice guidance (WLS_REPORTS Managed Server):"
info "  Dev/Test              : -Xmx1024m"
info "  Small production      : -Xmx1536m to -Xmx2048m"
info "  Large production      : -Xmx2048m to -Xmx4096m  (many parallel engines)"
info "  Rule of thumb         : heap < 60% of total physical RAM"
warn "IMPORTANT: Changes MUST be made in setDomainEnv.sh – the WebLogic Admin"
info "  Console does NOT apply memory settings for WLS_REPORTS!"
printf "\n"

SETDOMAINENV="${SETDOMAINENV:-$DOMAIN_HOME/bin/setDomainEnv.sh}"

if [ ! -f "$SETDOMAINENV" ]; then
    warn "setDomainEnv.sh not found: $SETDOMAINENV"
    info "  Check DOMAIN_HOME in environment.conf"
else
    printList "setDomainEnv.sh" 32 "$SETDOMAINENV"

    # Extract memory-related lines (non-comment)
    MEM_LINES="$(grep -nE 'USER_MEM_ARGS|WLS_MEM_ARGS|MEM_ARGS|Xms[0-9]|Xmx[0-9]' \
        "$SETDOMAINENV" | grep -v '^\s*#' | head -20)"

    if [ -z "$MEM_LINES" ]; then
        warn "No explicit memory settings found in setDomainEnv.sh"
        info "  WebLogic applies default JVM sizing – consider setting USER_MEM_ARGS"
    else
        info "Memory-related settings found:"
        while IFS= read -r line; do
            lineno="${line%%:*}"
            content="${line#*:}"
            printList "  Line $lineno" 12 "$content"

            # Assess Xmx values found
            xmx_raw="$(echo "$content" | grep -oE '\-Xmx[0-9]+[mMgG]' | head -1)"
            if [ -n "$xmx_raw" ]; then
                # Normalize to MB
                xmx_num="${xmx_raw//[^0-9]/}"
                xmx_unit="${xmx_raw##*[0-9]}"
                xmx_unit="${xmx_unit,,}"
                [ "$xmx_unit" = "g" ] && xmx_mb=$(( xmx_num * 1024 )) || xmx_mb="$xmx_num"

                if   [ "$xmx_mb" -lt 512 ];  then
                    fail  "  -Xmx${xmx_raw#-Xmx} (${xmx_mb}m) – below minimum recommendation (512m)"
                elif [ "$xmx_mb" -lt 1024 ]; then
                    warn  "  -Xmx${xmx_raw#-Xmx} (${xmx_mb}m) – acceptable for dev, low for production"
                elif [ "$xmx_mb" -le 4096 ]; then
                    ok    "  -Xmx${xmx_raw#-Xmx} (${xmx_mb}m) – within recommended production range"
                else
                    warn  "  -Xmx${xmx_raw#-Xmx} (${xmx_mb}m) – very large, verify available RAM"
                fi
            fi
        done <<< "$MEM_LINES"
    fi
fi

# =============================================================================
# Section 5: Log4j CVE Scan (read-only)
# =============================================================================
section "Log4j CVE Vulnerability Scan"

info "Scanning for log4j JARs under:"
info "  FMW_HOME    : $FMW_HOME"
info "  DOMAIN_HOME : $DOMAIN_HOME"
info "CVEs checked:"
info "  CVE-2021-44228 (Log4Shell)        log4j 2.0 – 2.14.1"
info "  CVE-2021-45046                    log4j 2.0 – 2.15.0"
info "  CVE-2021-45105                    log4j 2.0 – 2.16.0"
info "  CVE-2021-44832                    log4j 2.0 – 2.17.0"
info "  CVE-2019-17571 (log4j 1.x EOL)   log4j 1.x (no fix available)"
printf "\n"

LOG4J_COUNT=0
LOG4J_VULN=0

while IFS= read -r jar; do
    [ -f "$jar" ] || continue
    LOG4J_COUNT=$(( LOG4J_COUNT + 1 ))

    jar_name="$(basename "$jar")"
    version="$(_extract_log4j_version "$jar")"

    if [ -z "$version" ]; then
        warn "log4j JAR – version not determinable: $jar"
        info "  Inspect manually: unzip -p '$jar' META-INF/MANIFEST.MF"
        continue
    fi

    _classify_log4j "$version"
    rc=$?

    case $rc in
        0)
            ok "log4j $version – safe (>= 2.17.1): $jar_name"
            printList "  Path" 6 "$jar"
            ;;
        1)
            LOG4J_VULN=$(( LOG4J_VULN + 1 ))
            fail "log4j $version – VULNERABLE (Log4Shell family): $jar_name"
            printList "  Path" 6 "$jar"
            info "  Fix       : upgrade log4j to >= 2.17.1 or apply Oracle WLS patch"
            info "  Workaround: add LOG4J_FORMAT_MSG_NO_LOOKUPS=true to setDomainEnv.sh"
            ;;
        2)
            LOG4J_VULN=$(( LOG4J_VULN + 1 ))
            fail "log4j 1.x (End-of-Life) – CVE-2019-17571 and others: $jar_name"
            printList "  Path" 6 "$jar"
            info "  log4j 1.x has no security fix – must be replaced or removed"
            ;;
        3)
            warn "log4j JAR – unparseable version string '$version': $jar_name"
            printList "  Path" 6 "$jar"
            ;;
    esac

done < <(find "$FMW_HOME" "$DOMAIN_HOME" \
    -name "log4j*.jar" -not -path "*/ConfigBackup/*" 2>/dev/null | sort -u)

printf "\n"
printList "log4j JARs scanned" 32 "$LOG4J_COUNT"

if [ "$LOG4J_COUNT" -eq 0 ]; then
    info "No log4j JARs found – nothing to assess"
elif [ "$LOG4J_VULN" -gt 0 ]; then
    fail "Vulnerable or EOL log4j JARs found: $LOG4J_VULN – apply Oracle security patches"
else
    ok "All log4j JARs appear safe"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
exit $EXIT_CODE
