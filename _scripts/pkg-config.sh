#!/bin/bash
# Minimal self-contained pkg-config replacement for V8 host build.
# Reads .pc files from the glibc sysroot bundled in _deps/sysroots/.
# Avoids a host-environment dependency on /usr/bin/pkg-config.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYSROOT="${DEPS_DIR}/sysroots/debian_bullseye_amd64-sysroot"
PCDIR="${SYSROOT}/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig"

prefix=""

find_pc() {
    local pkg="$1"
    local d
    IFS=":"
    for d in $PCDIR; do
        [ -d "$d" ] || continue
        [ -f "$d/${pkg}.pc" ] && echo "$d/${pkg}.pc" && return 0
    done
    return 1
}

MODE=""
VARIABLE=""
PACKAGES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --modversion) MODE="modversion"; shift ;;
        --cflags) MODE="cflags"; shift ;;
        --libs) MODE="libs"; shift ;;
        --variable=*) VARIABLE="${1#*=}"; MODE="variable"; shift ;;
        --variable) VARIABLE="$2"; MODE="variable"; shift 2 ;;
        --define-variable=*) prefix="$(echo "${1#*=}" | sed 's/^prefix=//')"; shift ;;
        --define-variable) prefix="$(echo "$2" | sed 's/^prefix=//')"; shift 2 ;;
        --*) shift ;;
        -*) shift ;;
        *) PACKAGES="$PACKAGES $1"; shift ;;
    esac
done

PACKAGES=$(echo "$PACKAGES" | xargs)

first=true
for pkg in $PACKAGES; do
    pcfile=$(find_pc "$pkg") || continue

    pkg_prefix=$(grep "^prefix=" "$pcfile" 2>/dev/null | head -1 | sed 's/^prefix=//')
    [ -z "$pkg_prefix" ] && pkg_prefix="/usr"
    if [ -n "$prefix" ]; then
        pkg_prefix="$prefix"
    fi

    libdir=$(grep "^libdir=" "$pcfile" 2>/dev/null | head -1 | sed 's/^libdir=//')
    includedir=$(grep "^includedir=" "$pcfile" 2>/dev/null | head -1 | sed 's/^includedir=//')
    modversion=$(grep "^Version:" "$pcfile" 2>/dev/null | head -1 | sed 's/^Version:\s*//')
    cflags=$(grep "^Cflags:" "$pcfile" 2>/dev/null | head -1 | sed 's/^Cflags:\s*//')
    libs=$(grep "^Libs:" "$pcfile" 2>/dev/null | head -1 | sed 's/^Libs:\s*//')

    case "$libdir" in \$\{exec_prefix\}*|'${exec_prefix}'*) libdir="${pkg_prefix}${libdir#*prefix\}}" ;; esac
    case "$libdir" in \$\{prefix\}*|'${prefix}'*) libdir="${pkg_prefix}${libdir#*prefix\}}" ;; esac
    case "$includedir" in \$\{prefix\}*|'${prefix}'*) includedir="${pkg_prefix}${includedir#*prefix\}}" ;; esac

    cflags=$(echo "$cflags" | sed "s|\${includedir}|$includedir|g; s|\${libdir}|$libdir|g; s|\${prefix}|$pkg_prefix|g")
    libs=$(echo "$libs" | sed "s|\${libdir}|$libdir|g; s|\${prefix}|$pkg_prefix|g")

    case "$MODE" in
        modversion)
            [ -n "$modversion" ] && echo "$modversion"
            ;;
        variable)
            varname=$(echo "$VARIABLE" | tr '-' '_')
            val=$(grep "^${varname}=" "$pcfile" 2>/dev/null | head -1 | sed "s/^${varname}=//")
            if [ -n "$prefix" ] && [ "$varname" = "prefix" ]; then
                val="$prefix"
            fi
            echo "$val"
            ;;
        cflags)
            [ -n "$cflags" ] && echo -n "$cflags"
            ;;
        libs)
            [ -n "$libs" ] && echo -n "$libs"
            ;;
    esac
    first=false
done

case "$MODE" in cflags|libs) echo ;; esac
exit 0
