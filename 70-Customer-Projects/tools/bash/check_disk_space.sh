#!/bin/bash
# =============================================================================
# Script   : check_disk_space.sh
# Purpose  : Where is the space of the LOCAL disks? READ-ONLY – deletes nothing,
#            prints the clean command per finding.
#              1. file systems: local (scanned) / network (NFS, CIFS, …) –
#                 network mounts (e.g. the NFS-mounted ZFS patch archive) are
#                 NEVER scanned, also not below a local directory
#              2. usage tree per local file system, 2 levels below its mount
#                 point (du -x: stays on that file system); df used vs. du sum
#                 -> hidden space (deleted but open files, data under a mount
#                 point)
#              3. known space eaters with their clean command: dnf cache,
#                 journal, rotated logs, old kernels, core dumps, Oracle homes
#                 (.patch_storage, old homes after an out-of-place patch), ADR,
#                 audit, FRA, AutoUpgrade, WebLogic logs, staging, old JDKs …
#              4. deleted files still held open by a process
#              5. every single file larger than --big (default 500 MB)
# Call     : sudo ./check_disk_space.sh [--min MB] [--big MB] [--top N] [-t OUTDIR]
#              --min MB  smallest directory shown in the tree (default 100)
#              --big MB  smallest single file in section 5 (default 500)
#              --top N   at most N entries per tree level (default 15)
#              -t DIR    directory of the report file (default /tmp)
# Runs as  : root (sudo) – as another user directories without read access
#            are missing and section 4 only sees the own processes
# Output   : stdout + <OUTDIR>/check_disk_space_<host>_<yyyymmdd_hhmmss>.log
# Exit     : 0 = all local file systems < 85 % used, 1 = one >= 85 %,
#            2 = one >= 95 % / error
# Doc      : 70-Customer-Projects/tools/README.md
# Author   : Gunther Pipperr | https://pipperr.de
# License  : Apache 2.0
# =============================================================================
set -u
VERSION="2026-10-30.1"   # bump on every change

MIN_MB=100; BIG_MB=500; TOP=15; OUTBASE="/tmp"
while [ $# -gt 0 ]; do
    case "$1" in
        --min) MIN_MB="${2:-100}"; shift ;;
        --big) BIG_MB="${2:-500}"; shift ;;
        --top) TOP="${2:-15}"; shift ;;
        -t)    OUTBASE="${2:-/tmp}"; shift ;;
        -h|--help) sed -n '2,32p' "$0"; printf 'Version: %s\n' "$VERSION"; exit 0 ;;
        -V|--version) printf '%s\n' "$VERSION"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
for _n in "$MIN_MB" "$BIG_MB" "$TOP"; do
    [[ "$_n" =~ ^[0-9]+$ ]] || { printf 'Not a number: %s\n' "$_n" >&2; exit 2; }
done

H_SHORT="$(hostname -s 2>/dev/null)"
LOG="$OUTBASE/check_disk_space_${H_SHORT:-host}_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG" 2>/dev/null || LOG=/dev/null       # a full disk must not stop the check
WARNS=0; RC=0

# --- output helpers (stdout + log) ----------------------------------------------
_p()   { printf '%s\n' "$*" | tee -a "$LOG"; }
ok()   { printf '\033[32m  OK  \033[0m %s\n' "$*"; printf '  OK   %s\n' "$*" >> "$LOG"; }
warn() { WARNS=$((WARNS + 1)); printf '\033[33m WARN \033[0m %s\n' "$*"; printf ' WARN  %s\n' "$*" >> "$LOG"; }
info() { printf '       %s\n' "$*" | tee -a "$LOG"; }
cmd()  { printf '\033[36m       clean: %s\033[0m\n' "$*"; printf '       clean: %s\n' "$*" >> "$LOG"; }
section() { _p ""; _p "=== $* ==="; }
_h()   { numfmt --to=iec --format='%.1f' "${1:-0}" 2>/dev/null || printf '%s' "${1:-0}"; }

# =============================================================================
# File systems: local disk vs. network vs. pseudo
# =============================================================================
# network types are never scanned; everything not in LOCAL_TYPES is pseudo /
# memory (proc, tmpfs, overlay, squashfs …) and not relevant for the disk
NET_TYPES=" nfs nfs4 cifs smb3 smbfs fuse.sshfs fuse.s3fs fuse.rclone glusterfs fuse.glusterfs ceph 9p davfs lustre gpfs "
LOCAL_TYPES=" xfs ext2 ext3 ext4 btrfs zfs vfat jfs reiserfs f2fs "
LOCAL=(); NET=(); declare -A _SEEN_DEV=()
while read -r _dev _mnt _type _rest; do
    _mnt="$(printf '%b' "${_mnt//\\/\\\\0}")"     # \040 -> blank
    case "$NET_TYPES" in *" $_type "*) NET+=("$_mnt|$_type|$_dev"); continue ;; esac
    case "$LOCAL_TYPES" in *" $_type "*) ;; *) continue ;; esac
    # bind mounts / second mount of the same file system: scan it once
    _id="$(stat -c '%d' "$_mnt" 2>/dev/null)"
    [ -n "$_id" ] && [ -n "${_SEEN_DEV[$_id]:-}" ] && continue
    _SEEN_DEV[$_id]=1
    LOCAL+=("$_mnt")
done < <(awk '{print $1, $2, $3}' /proc/self/mounts)
unset _dev _mnt _type _rest _id

_is_local_mount() { local m; for m in "${LOCAL[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1; }
_net_of() { local n; for n in "${NET[@]}"; do [ "${n%%|*}" = "$1" ] && { printf '%s' "${n#*|}"; return 0; }; done; return 1; }
# path on a network file system (also below such a mount)?
_on_net() {
    local t; t="$(findmnt -n -o FSTYPE -T "$1" 2>/dev/null | head -1)"
    case "$NET_TYPES" in *" $t "*) return 0 ;; esac
    return 1
}

_p "check_disk_space.sh $VERSION – $(hostname -f 2>/dev/null) – $(date '+%Y-%m-%d %H:%M:%S')"
_p "Report: $LOG"
[ "$(id -u)" -eq 0 ] || warn "not root – directories without read access are missing, run with sudo for the full picture"

section "1. File systems"
_p "$(printf '  %-28s %-6s %8s %8s %8s %5s' "Mount point" "Type" "Size" "Used" "Free" "Use%")"
for _m in "${LOCAL[@]}"; do
    read -r _size _used _avail _pct < <(df -PB1 "$_m" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $2, $3, $4, $5 }')
    _t="$(findmnt -n -o FSTYPE -T "$_m" | head -1)"
    _line="$(printf '%-28s %-6s %8s %8s %8s %4s%%' "$_m" "$_t" "$(_h "$_size")" "$(_h "$_used")" "$(_h "$_avail")" "${_pct:-?}")"
    if [ "${_pct:-0}" -ge 95 ]; then warn "$_line  <- FULL"; RC=2
    elif [ "${_pct:-0}" -ge 85 ]; then warn "$_line  <- nearly full"; [ "$RC" -lt 1 ] && RC=1
    else ok "$_line"
    fi
done
if [ "${#NET[@]}" -gt 0 ]; then
    _p ""
    _p "  Network file systems – NOT scanned (no local disk space):"
    for _n in "${NET[@]}"; do
        IFS='|' read -r _m _t _d <<< "$_n"
        info "$(printf '%-28s %-6s %s' "$_m" "$_t" "$_d")"
    done
fi
unset _m _t _d _n _size _used _avail _pct _line

# =============================================================================
# 2. Usage tree per local file system
# =============================================================================
TMPD="$(mktemp -d 2>/dev/null || printf '/tmp/check_disk_space.%s' "$$")"
mkdir -p "$TMPD"; trap 'rm -rf "$TMPD"' EXIT
MIN_B=$(( MIN_MB * 1024 * 1024 ))

# label of a directory that is a mount point of another file system
_mark() {
    local t
    if t="$(_net_of "$1")"; then printf '  [%s – network, not scanned]' "${t%%|*}"
    elif _is_local_mount "$1"; then printf '  [own file system, see below]'
    fi
}

section "2. Usage tree – 2 levels per local file system (>= ${MIN_MB} MB, top $TOP)"
for _m in "${LOCAL[@]}"; do
    _du="$TMPD/du.txt"
    # -x: stay on this file system (nested local mounts get their own tree,
    # NFS below it is never entered)
    du -x -B1 --max-depth=2 "$_m" 2>/dev/null > "$_du"
    _base="${_m%/}"
    _total="$(awk -v m="$_m" -F'\t' '$2 == m { print $1 }' "$_du")"
    _dfused="$(df -PB1 "$_m" 2>/dev/null | awk 'NR == 2 { print $3 }')"
    _p ""
    _p "$(printf '  %s  (du %s, df used %s)' "$_m" "$(_h "$_total")" "$(_h "$_dfused")")"
    # level 1 = path with exactly one more "/" than the mount point
    awk -F'\t' -v b="$_base" -v min="$MIN_B" '
        { p = $2; if (p == b || p == b "/" || index(p, b "/") != 1 && b != "") next
          r = substr(p, length(b) + 2); n = split(r, a, "/")
          if (n == 1 && $1 >= min) print $1 "\t" p }' "$_du" | sort -rn | head -n "$TOP" \
    | while IFS=$'\t' read -r _s1 _p1; do
        _p "$(printf '    %8s  %s%s' "$(_h "$_s1")" "$_p1" "$(_mark "$_p1")")"
        awk -F'\t' -v par="$_p1" -v min="$MIN_B" '
            index($2, par "/") == 1 && $1 >= min && substr($2, length(par) + 2) !~ /\// { print $1 "\t" $2 }' "$_du" \
            | sort -rn | head -n "$TOP" | while IFS=$'\t' read -r _s2 _p2; do
                _p "$(printf '      %8s  %s%s' "$(_h "$_s2")" "$_p2" "$(_mark "$_p2")")"
            done
    done
    # mount points of other file systems below this one (size 0 in du, listed
    # so nobody wonders where e.g. the patch archive went)
    for _n in "${NET[@]}"; do
        _nm="${_n%%|*}"
        case "$_nm" in "$_base"/*) [ "$(findmnt -n -o TARGET -T "$(dirname "$_nm")" | head -1)" = "$_m" ] \
            && info "$(printf '%8s  %s%s' "-" "$_nm" "$(_mark "$_nm")")" ;; esac
    done
    # df used vs. du: the difference is space du cannot see
    if [ -n "$_total" ] && [ -n "$_dfused" ]; then
        _diff=$(( _dfused - _total ))
        if [ "$_diff" -gt 1073741824 ] && [ "$_diff" -gt $(( _dfused / 20 )) ]; then
            warn "$(printf '%s: df used is %s more than du finds – hidden space' "$_m" "$(_h "$_diff")")"
            info "  a) deleted files still open (section 4) – restart that process"
            info "  b) files UNDER a mount point (written before the NFS / disk was mounted):"
            info "     mkdir -p /mnt/rootcheck && mount --bind $_m /mnt/rootcheck && du -xsh /mnt/rootcheck/*; umount /mnt/rootcheck"
        fi
    fi
done
unset _m _du _base _total _dfused _diff _s1 _p1 _s2 _p2 _n _nm

# =============================================================================
# 3. Known space eaters
# =============================================================================
# locations from the environment, the IHateWeblogic environment.conf (when the
# script runs from the repository) or the usual defaults
_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
_conf_val() {
    [ -f "$_REPO/environment.conf" ] || return 0
    # subshell: the conf may set and override anything
    ( source "$_REPO/environment.conf" > /dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" )
}
OB="${ORACLE_BASE:-$(_conf_val ORACLE_BASE)}";       [ -z "$OB" ] && [ -d /u01/app/oracle ] && OB=/u01/app/oracle
DH="${DOMAIN_HOME:-$(_conf_val DOMAIN_HOME)}"
PS_DIR="${PATCH_STORAGE:-$(_conf_val PATCH_STORAGE)}"

# Oracle homes from the central inventory (FMW, DB, old DB home after an
# out-of-place patch, client …)
HOMES=()
_inv="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null | head -1)"
if [ -r "$_inv/ContentsXML/inventory.xml" ]; then
    while IFS= read -r _h1; do [ -d "$_h1" ] && HOMES+=("$_h1"); done < <(
        grep -E '<HOME ' "$_inv/ContentsXML/inventory.xml" | grep -v 'REMOVED="T"' \
            | sed -n 's/.*LOC="\([^"]*\)".*/\1/p' | sort -u)
fi

EATERS="$TMPD/eaters.txt"; : > "$EATERS"
# _eater LABEL PATH CLEAN-CMD – size of PATH (skipped on NFS / missing)
_eater() {
    local label="$1" path="$2" clean="$3" s
    [ -e "$path" ] || return 0
    _on_net "$path" && return 0
    s="$(du -sxB1 "$path" 2>/dev/null | cut -f1)"
    [ -n "$s" ] && [ "$s" -gt 0 ] && printf '%s|%s|%s|%s\n' "$s" "$label" "$path" "$clean" >> "$EATERS"
}
# _eater_find LABEL DIR FIND-ARGS… – sum of the files matched by find
_eater_find() {
    local label="$1" dir="$2" clean="$3" s; shift 3
    [ -d "$dir" ] || return 0
    _on_net "$dir" && return 0
    s="$(find "$dir" -xdev -type f "$@" -printf '%s\n' 2>/dev/null | awk '{ t += $1 } END { print t + 0 }')"
    [ "${s:-0}" -gt 0 ] && printf '%s|%s|%s|%s\n' "$s" "$label" "$dir" "$clean" >> "$EATERS"
}

# --- OS ---
_eater "dnf package cache"        /var/cache/dnf          "dnf clean all"
_eater "yum package cache"        /var/cache/yum          "yum clean all"
_eater "PackageKit cache"         /var/cache/PackageKit   "pkcon refresh force -c -1  (or: rm -rf /var/cache/PackageKit/*)"
_eater "systemd journal"          /var/log/journal        "journalctl --vacuum-size=500M"
_eater_find "rotated logs in /var/log" /var/log \
    "find /var/log -xdev -type f \\( -name '*.gz' -o -name '*-[0-9]*[0-9]' -o -name '*.[0-9]' \\) -mtime +30 -delete  (review with -print first)" \
    \( -name '*.gz' -o -name '*-[0-9]*[0-9]' -o -name '*.[0-9]' \)
_eater "kernel crash dumps"       /var/crash              "rm -rf /var/crash/*  (after the analysis)"
_eater "systemd core dumps"       /var/lib/systemd/coredump "coredumpctl list; rm -f /var/lib/systemd/coredump/*"
_eater "core dumps (Oracle core_pattern)" /var/tmp/core   "ls -l /var/tmp/core; rm -f /var/tmp/core/coredump_*  (after the analysis)"
_eater "/tmp"                     /tmp                    "ls -la /tmp – only remove what no running process uses (OraInstall*, *.zip)"
_eater "/var/tmp"                 /var/tmp                "ls -la /var/tmp"
_eater "container storage"        /var/lib/containers     "podman system prune -a"
_eater "root cache"               /root/.cache            "rm -rf /root/.cache/*"
# old kernels: installonly packages beyond the running one
if command -v rpm > /dev/null 2>&1; then
    _nk="$(rpm -q kernel-uek kernel 2>/dev/null | grep -vc 'not installed')"
    [ "${_nk:-0}" -gt 2 ] && _eater "kernels ($_nk installed, modules)" /lib/modules \
        "dnf remove --oldinstallonly --setopt installonly_limit=2  (keeps the running + 1)"
fi
# swap file on the root disk
while read -r _sf _st _ss _rest; do
    [ "$_st" = "file" ] && printf '%s|%s|%s|%s\n' "$(( _ss * 1024 ))" "swap file (needed, info only)" "$_sf" "-" >> "$EATERS"
done < <(tail -n +2 /proc/swaps 2>/dev/null)

# --- Oracle ---
# in use = a process runs from it (binary or command line, e.g. WebLogic's
# -Dweblogic.home), /etc/oratab names it, or a domain is registered on it
PROCS="$TMPD/procs.txt"; : > "$PROCS"
for _pd in /proc/[0-9]*; do
    { readlink "$_pd/exe" 2>/dev/null; tr '\0' ' ' < "$_pd/cmdline" 2>/dev/null; printf '\n'; } >> "$PROCS"
done
_home_in_use() {
    grep -qE "^[^#][^:]*:$1/?:" /etc/oratab 2>/dev/null && return 0
    [ -f "$1/domain-registry.xml" ] && grep -q 'location=' "$1/domain-registry.xml" 2>/dev/null && return 0
    grep -qF -- "$1/" "$PROCS"
}
for _oh in "${HOMES[@]}"; do
    if _home_in_use "$_oh"; then
        _eater "Oracle home (in use)" "$_oh" "-"
    else
        _eater "Oracle home NOT in use (old?)" "$_oh" \
            "no process, not in /etc/oratab, no domain – old home after an out-of-place patch? su - oracle -c '$_oh/deinstall/deinstall'"
    fi
    _eater "OPatch rollback data" "$_oh/.patch_storage" \
        "su - oracle -c 'cd $_oh && ORACLE_HOME=$_oh OPatch/opatch util cleanup -silent'"
done
if [ -n "$OB" ] && [ -d "$OB" ]; then
    _eater "staging \$ORACLE_BASE/tmp"     "$OB/tmp"           "07-Maintenance/patch_storage.sh clean --apply  (IHateWeblogic) – else ls -la $OB/tmp"
    _eater "AutoUpgrade (patches, gold image)" "$OB/autoupgrade" "after the DB install: ls -l $OB/autoupgrade/patchdir; rm -f $OB/autoupgrade/patchdir/*.zip (gold image, base ZIP – only for a re-install)"
    _eater "ADR diag (alert, trace, incidents)" "$OB/diag"     "su - oracle -c \"adrci exec='show homes'\"; per home: adrci exec=\"set home <home>; purge -age 10080\""
    _eater_find "DB audit files (*.aud)" "$OB/admin" \
        "find $OB/admin -name '*.aud' -mtime +30 -delete" -name '*.aud'
    for _fra in "$OB/fast_recovery_area" "$OB/flash_recovery_area"; do
        _eater "DB fast recovery area"     "$_fra"             "RMAN: delete noprompt archivelog all completed before 'sysdate-7';"
    done
    _eater "DB data files (info)"          "$OB/oradata"       "-"
    _eater "CVU home (00b- done)"          "$OB/cvu"           "rm -rf $OB/cvu  (unpacked again by 60-RCU-DB-19c/00b-)"
    # JDKs: all but the one the symlink points to
    for _jd in "$OB"/java/jdk-* "$OB"/java/jdk1*; do
        [ -d "$_jd" ] && [ ! -L "$_jd" ] || continue
        if ! ls -l "$OB"/java/ 2>/dev/null | grep -- '->' | grep -q -- "$(basename "$_jd")"; then
            _eater "JDK not linked (old?)" "$_jd" "in use? (ps -ef | grep $(basename "$_jd")) – then rm -rf $_jd"
        fi
    done
    for _tmpd in "$OB"/tmp/OraInstall* /tmp/OraInstall*; do
        [ -d "$_tmpd" ] && _eater "OUI leftover" "$_tmpd" "rm -rf $_tmpd  (no installer running)"
    done
fi
[ -n "$PS_DIR" ] && _eater "PATCH_STORAGE (local copy)" "$PS_DIR" \
    "07-Maintenance/patch_storage.sh status / clean --apply  (IHateWeblogic)"
if [ -n "$DH" ] && [ -d "$DH/servers" ]; then
    _eater_find "WebLogic rotated logs" "$DH/servers" \
        "find $DH/servers -path '*/logs/*' -name '*.log[0-9]*' -mtime +14 -delete" -path '*/logs/*' -name '*.log[0-9]*'
    _eater_find "WebLogic logs (all)" "$DH/servers" "rotation: 03-Logs/ (IHateWeblogic) – current logs stay" -path '*/logs/*'
    for _sd in "$DH"/servers/*/tmp "$DH"/servers/*/cache; do
        _eater "WebLogic $(basename "$(dirname "$_sd")")/$(basename "$_sd")" "$_sd" "only with the server STOPPED: rm -rf $_sd/*"
    done
fi
[ -d "$_REPO/log" ] && _eater "IHateWeblogic logs" "$_REPO/log" "find $_REPO/log -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +"
[ -d "$_REPO/07-Maintenance/ConfigBackup" ] && _eater "IHateWeblogic config backups" "$_REPO/07-Maintenance/ConfigBackup" \
    "07-Maintenance/backup_config.sh retention (IHateWeblogic)"

section "3. Known space eaters (largest first, >= 10 MB)"
sort -t'|' -k1,1 -rn "$EATERS" | while IFS='|' read -r _s _l _pa _c; do
    [ "$_s" -ge 10485760 ] || continue
    _p "$(printf '  %8s  %-36s %s' "$(_h "$_s")" "${_l:0:36}" "$_pa")"
    [ "$_c" != "-" ] && cmd "$_c"
done
[ -s "$EATERS" ] || info "nothing found"
[ "${#HOMES[@]}" -gt 0 ] && info "Oracle homes from the inventory $_inv: ${#HOMES[@]}"
unset _pd _oh _fra _jd _tmpd _sd _s _l _pa _c _nk _sf _st _ss _rest _h1

# =============================================================================
# 4. Deleted files still held open
# =============================================================================
section "4. Deleted but still open files (space is freed only when the process ends)"
DEL="$TMPD/deleted.txt"; : > "$DEL"
for _fd in /proc/[0-9]*/fd/*; do
    _t="$(readlink "$_fd" 2>/dev/null)" || continue
    case "$_t" in *" (deleted)") ;; *) continue ;; esac
    case "$_t" in /memfd:*|/dev/*|/SYSV*) continue ;; esac
    _s="$(stat -L -c %s "$_fd" 2>/dev/null)" || continue
    _pid="${_fd#/proc/}"; _pid="${_pid%%/*}"
    printf '%s|%s|%s|%s\n' "${_s:-0}" "$_pid" "$(cat "/proc/$_pid/comm" 2>/dev/null)" "${_t% (deleted)}" >> "$DEL"
done
if [ -s "$DEL" ]; then
    _sum="$(sort -u "$DEL" | awk -F'|' '{ t += $1 } END { print t + 0 }')"
    if [ "$_sum" -ge 104857600 ]; then
        warn "$(printf 'deleted files still open: %s in total – restart the process to free it' "$(_h "$_sum")")"
    else
        ok "$(printf 'deleted files still open: %s (small)' "$(_h "$_sum")")"
    fi
    sort -t'|' -k1,1 -rn "$DEL" | sort -u -t'|' -k4,4 | sort -t'|' -k1,1 -rn | head -10 \
        | while IFS='|' read -r _s _pid _c _f; do
            [ "$_s" -gt 0 ] && info "$(printf '%8s  pid %-7s %-16s %s' "$(_h "$_s")" "$_pid" "$_c" "$_f")"
        done
else
    ok "none$([ "$(id -u)" -eq 0 ] || printf ' (own processes only – not root)')"
fi
unset _fd _t _s _pid _sum _c _f

# =============================================================================
# 5. Single files larger than --big
# =============================================================================
section "5. Single files >= ${BIG_MB} MB (local file systems)"
BIG="$TMPD/big.txt"; : > "$BIG"
for _m in "${LOCAL[@]}"; do
    find "$_m" -xdev -type f -size +"$(( BIG_MB - 1 ))"M -printf '%s\t%TY-%Tm-%Td\t%u\t%p\n' 2>/dev/null >> "$BIG"
done
if [ -s "$BIG" ]; then
    _p "$(printf '  %8s  %-10s  %-8s  %s' "Size" "Modified" "Owner" "File")"
    sort -rn "$BIG" | while IFS=$'\t' read -r _s _d _u _f; do
        _p "$(printf '  %8s  %-10s  %-8s  %s' "$(_h "$_s")" "$_d" "$_u" "$_f")"
    done
    _p "$(printf '  %8s  in %d file(s)' "$(_h "$(awk -F'\t' '{ t += $1 } END { print t + 0 }' "$BIG")")" "$(wc -l < "$BIG")")"
else
    ok "no file >= ${BIG_MB} MB"
fi
unset _m _s _d _u _f

section "Summary"
_p "  local file systems: ${#LOCAL[@]} scanned, network file systems: ${#NET[@]} skipped"
_p "  warnings: $WARNS   exit code: $RC   report: $LOG"
_p "  read-only – nothing was deleted; check each clean command before running it"
exit "$RC"
