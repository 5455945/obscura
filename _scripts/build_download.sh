#!/bin/bash
# ============================================================
# build_download.sh - Download build dependencies (clang, libclang, cmake, sysroot, cargo vendor)
#
# Usage:
#   Standalone: ./build_download.sh [options]
#   Sourced:    source ./build_download.sh  (get variables and functions, no download)
#
# Options:
#   --skip-clang       Skip clang download
#   --skip-libclang    Skip libclang download
#   --skip-cmake       Skip cmake download (needed for --features stealth)
#   --skip-sysroot     Skip sysroot download
#   --skip-vendor      Skip cargo vendor
#   --vendor-only      Only run cargo vendor (skip all other downloads)
#   --force            Force re-download of existing files
#   -h, --help         Show help
# ============================================================

# Prevent duplicate loading
[[ -n "$_BUILD_DOWNLOAD_LOADED" ]] && return 0 2>/dev/null
_BUILD_DOWNLOAD_LOADED=1

# ===================== Common Variables =====================
# Resolve project root directory (realpath handles symlinks cross-platform: Linux / macOS / MSYS2 / MinGW64)
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# Reuse V8's bundled sysroot (for both V8 GN build and Rust/cargo clang)
# Match v8-X.Y.Z format precisely (e.g. v8-137.3.0), not v8-137.3.0.bak or v8-137.3.0_xx
V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

# Build tools cached uniformly under _deps/ (clang, ninja/gn, sysroot, etc.), shared across profiles to avoid re-download
DEPS_DIR="${OBSCURA_DIR}/_deps"

# V8 downloaded clang
CLANG_DIR="${DEPS_DIR}/clang"

# sysroot cached under _deps/sysroots/, referenced via symlinks in V8 tree
# This way cargo vendor cleaning third_party/ won't lose downloaded sysroots
SYSROOT_CACHE_DIR="${DEPS_DIR}/sysroots"
SYSROOT_DIR="${SYSROOT_CACHE_DIR}/debian_bullseye_arm64-sysroot"
AMD64_SYSROOT_DIR="${SYSROOT_CACHE_DIR}/debian_bullseye_amd64-sysroot"

# ninja/gn binaries (needed for V8 build)
NINJA_GN_DIR="${DEPS_DIR}/ninja_gn_binaries"

# Rust cross-compilation toolchain (glob matches any version: rust-1.95.0, rust-1.96.0, etc.)
RUST_DIR=$(ls -td "${DEPS_DIR}"/rust-[0-9]*.[0-9]*.[0-9]*-x86_64-unknown-linux-gnu 2>/dev/null | head -1)

# cmake (needed for --features stealth: BoringSSL/btls-sys build dependency)
CMAKE_DIR="${DEPS_DIR}/cmake"
CMAKE_VERSION="3.31.6"

# libclang.so (needed for bindgen, not included in Chromium's clang package)
# Version and URL dynamically obtained from V8 source in download_libclang()
LIBCLANG_DEB="/tmp/libclang1.deb"
LIBCLANG_DOWNLOAD_RETRIES=3

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Cargo config file paths
CARGO_CONFIG="${OBSCURA_DIR}/.cargo/config.toml"
CARGO_CONFIG_VENDOR="${OBSCURA_DIR}/.cargo/config.toml.vendor"
CARGO_CONFIG_BUILD="${OBSCURA_DIR}/.cargo/config.toml.build"


_create_relative_symlink() {
    local target="$1"
    local link="$2"

    if [[ -z "$target" || -z "$link" ]]; then
        echo "❌ Usage: create_relative_symlink <target> <link>" >&2
        return 1
    fi

    mkdir -p "$(dirname "$link")" || {
        echo " ❌ Unable to create directory: $(dirname "$link") ">&2
        return 1
    }

    local rel_path
    if rel_path="$(realpath --relative-to="$(dirname "$link")" "$target" 2>/dev/null)"; then
        ln -sf "$rel_path" "$link"
        echo "✅ Created relatively soft link: $link -> $rel_path"
    else
        ln -sf "$target" "$link"
        echo " ⚠️ Absolute soft link created: $link -> $target " >&2
    fi
}

# ===================== Download Functions =====================

download_clang() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CLANG_DIR" ]]; then
        echo "=== [--force] Removing existing clang directory: $CLANG_DIR ==="
        rm -rf "$CLANG_DIR"
    fi

    if [ ! -f "$CLANG_DIR/bin/clang" ]; then
        echo "=== Pre-downloading V8's clang ==="
        echo -e "Tool: ${BLUE}V8 tools/clang/scripts/update.py${NC}"
        echo -e "Path: ${BLUE}${CLANG_DIR}${NC}"
        ( cd "$V8_SRC_DIR" && python3 ./tools/clang/scripts/update.py --output-dir="$CLANG_DIR" --host-os=linux )
        if [ $? -ne 0 ]; then
            echo "Error: clang download failed"
            return 1
        fi
        echo "=== clang download complete: $CLANG_DIR ==="
        echo ""
    else
        echo -e "${BLUE}clang ready: $CLANG_DIR${NC}"
    fi
}

# Check Rust latest stable version, notify if newer than local
# This function is best-effort: silently skips on network failure, doesn't affect build flow
_check_rust_latest() {
    # Extract version from local directory name, e.g. .../rust-1.95.0-x86_64-unknown-linux-gnu → 1.95.0
    local LOCAL_VERSION
    LOCAL_VERSION=$(basename "$RUST_DIR" | sed -n 's/.*rust-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$LOCAL_VERSION" ]; then
        return 0
    fi

    # Download channel TOML (best-effort, 5s timeout, silent on failure)
    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML
    CHANNEL_TOML=$(mktemp /tmp/channel-rust-stable.XXXXXX.toml)
    if ! wget -q --timeout=5 -O "$CHANNEL_TOML" "$CHANNEL_URL" 2>/dev/null; then
        rm -f "$CHANNEL_TOML"
        return 0
    fi

    # Extract latest version from [pkg.rustc.target.x86_64-unknown-linux-gnu] section url
    local HOST_URL LATEST_VERSION
    HOST_URL=$(awk '/^\[pkg\.rustc\.target\.x86_64-unknown-linux-gnu\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")
    rm -f "$CHANNEL_TOML"

    if [ -z "$HOST_URL" ]; then
        return 0
    fi
    LATEST_VERSION=$(echo "$HOST_URL" | sed -n 's/.*rustc\{0,1\}-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$LATEST_VERSION" ]; then
        return 0
    fi

    # Version comparison: use sort -V to sort by version number, check if LATEST_VERSION > LOCAL_VERSION
    if [ "$LOCAL_VERSION" != "$LATEST_VERSION" ] && \
       [ "$(printf '%s\n%s' "$LOCAL_VERSION" "$LATEST_VERSION" | sort -V | tail -n1)" = "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}Notice: Found Rust latest stable version ${LATEST_VERSION} (local: ${LOCAL_VERSION})${NC}"
        echo -e "${YELLOW}        To upgrade, remove local toolchain and re-run: rm -rf ${RUST_DIR}${NC}"
    fi
}

download_rust_toolchain() {
    # Check if any version of Rust toolchain exists (glob regex match)
    if [ -n "$RUST_DIR" ] && [ -x "$RUST_DIR/rustc/bin/rustc" ]; then
        if [[ "$BD_FORCE" == "1" ]]; then
            echo "=== [--force] Removing existing Rust toolchain: $RUST_DIR ==="
            rm -rf "$RUST_DIR"
        else
            echo -e "${BLUE}Rust toolchain ready: $RUST_DIR ${NC}"
            # Online check for latest stable version, notify if update available (best-effort, silent on network failure)
            _check_rust_latest
            return 0
        fi
    fi

    echo "=== Downloading Rust stable cross-compilation toolchain ==="

    # 1. Get stable channel TOML, parse latest version download URL
    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML="/tmp/channel-rust-stable.toml"

    echo -e "Downloading channel manifest: ${BLUE}${CHANNEL_URL}${NC}"
    wget -q -O "$CHANNEL_TOML" "$CHANNEL_URL"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to download channel manifest"
        return 1
    fi

    # 2. Extract x86_64 and aarch64 URLs from [pkg.rustc.target.*] sections
    #    Use awk to limit to pkg.rustc section, avoid picking up rust-std/rust-docs etc.
    local HOST_URL TARGET_URL
    HOST_URL=$(awk '/^\[pkg\.rustc\.target\.x86_64-unknown-linux-gnu\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")
    TARGET_URL=$(awk '/^\[pkg\.rustc\.target\.aarch64-unknown-linux-gnu\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")

    if [ -z "$HOST_URL" ] || [ -z "$TARGET_URL" ]; then
        echo "Error: Cannot extract rustc URLs from channel manifest"
        rm -f "$CHANNEL_TOML"
        return 1
    fi

    # 3. Extract date (e.g. 2026-05-28) and version (e.g. 1.96.0) from URL path
    local DOWNLOAD_DATE RUST_VERSION
    DOWNLOAD_DATE=$(echo "$HOST_URL" | sed -n 's/.*dist\/\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p')
    RUST_VERSION=$(echo "$HOST_URL" | sed -n 's/.*rust\(c\)\{0,1\}-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\2/p')

    # 4. Construct tarball URLs and filenames
    local HOST_TARBALL="rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
    local TARGET_TARBALL="rust-${RUST_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
    local HOST_TAR_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/${HOST_TARBALL}"
    local TARGET_TAR_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/${TARGET_TARBALL}"

    echo -e "Rust version:  ${BLUE}${RUST_VERSION}${NC}"
    echo -e "Release date:  ${BLUE}${DOWNLOAD_DATE}${NC}"
    echo -e "Host URL:      ${BLUE}${HOST_TAR_URL}${NC}"
    echo -e "Target URL:    ${BLUE}${TARGET_TAR_URL}${NC}"

    rm -f "$CHANNEL_TOML"

    # 5. Download two tarballs to /tmp
    echo ">>> Downloading host toolchain (x86_64)..."
    wget -c -P /tmp "$HOST_TAR_URL" || { echo "Error: Failed to download host toolchain"; return 1; }
    echo ">>> Downloading target standard library (aarch64)..."
    wget -c -P /tmp "$TARGET_TAR_URL" || { echo "Error: Failed to download target standard library"; return 1; }

    # 6. Extract x86_64 toolchain to _deps/
    mkdir -p "${DEPS_DIR}"
    echo ">>> Extracting x86_64 toolchain to ${DEPS_DIR}..."
    tar xzf "/tmp/${HOST_TARBALL}" -C "${DEPS_DIR}"
    local RUST_EXTRACTED="${DEPS_DIR}/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu"
    if [ ! -d "$RUST_EXTRACTED" ]; then
        echo "Error: Extracted directory not found: $RUST_EXTRACTED"
        return 1
    fi

    # 7. Extract aarch64 standard library to /tmp (temporary)
    echo ">>> Extracting aarch64 standard library..."
    tar xzf "/tmp/${TARGET_TARBALL}" -C /tmp/

    # 8. Assemble cross-compilation toolchain
    #    Copy x86_64 standard library top-level lib/ to toolchain root directory
    cp -ar "${RUST_EXTRACTED}/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu" "${RUST_EXTRACTED}/rustc/lib/rustlib/"

    #    Add aarch64 standard library to rustlib/ (for cross-compilation)
    cp -ar "/tmp/rust-${RUST_VERSION}-aarch64-unknown-linux-gnu/rust-std-aarch64-unknown-linux-gnu/lib/rustlib/aarch64-unknown-linux-gnu" \
           "${RUST_EXTRACTED}/rustc/lib/rustlib/"

    # 9. Clean up tarballs and extracted dirs in /tmp
    #rm -f "/tmp/${HOST_TARBALL}" "/tmp/${TARGET_TARBALL}"
    #rm -rf "/tmp/rust-${RUST_VERSION}-aarch64-unknown-linux-gnu"

    # 10. Update RUST_DIR global variable
    RUST_DIR="$RUST_EXTRACTED"

    echo -e "${BLUE}=== Rust ${RUST_VERSION} cross-compilation toolchain ready: $RUST_DIR ===${NC}"
    echo ""
}

download_ninja_gn() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$NINJA_GN_DIR" ]]; then
        echo "=== [--force] Removing existing ninja_gn_binaries directory: $NINJA_GN_DIR ==="
        rm -rf "$NINJA_GN_DIR"
    fi

    # Check if both gn and ninja exist
    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        echo -e "${BLUE}ninja/gn ready: $NINJA_GN_DIR${NC}"
        return 0
    fi

    echo "=== Downloading ninja/gn binaries ==="
    echo -e "Tool: ${BLUE}V8 tools/ninja_gn_binaries.py${NC}"
    echo -e "Path: ${BLUE}${NINJA_GN_DIR}${NC}"
    mkdir -p "$NINJA_GN_DIR"
    ( cd "$V8_SRC_DIR" && python3 ./tools/ninja_gn_binaries.py --dir="$NINJA_GN_DIR" )
    if [ $? -ne 0 ]; then
        echo "Error: ninja/gn download failed"
        return 1
    fi
    echo "=== ninja/gn download complete: $NINJA_GN_DIR ==="
    echo ""
}

download_cmake() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CMAKE_DIR" ]]; then
        echo "=== [--force] Removing existing cmake directory: $CMAKE_DIR ==="
        rm -rf "$CMAKE_DIR"
    fi

    if [ -x "$CMAKE_DIR/bin/cmake" ]; then
        echo -e "${BLUE}cmake ready: $CMAKE_DIR/bin/cmake ($("$CMAKE_DIR/bin/cmake" --version | head -1))${NC}"
        return 0
    fi

    echo "=== Downloading cmake ${CMAKE_VERSION} (needed for --features stealth) ==="

    # Determine platform suffix
    local PLATFORM_SUFFIX
    case "$(uname -s)" in
        Linux)  PLATFORM_SUFFIX="linux-x86_64" ;;
        Darwin) PLATFORM_SUFFIX="macos-universal" ;;
        *)
            echo -e "${RED}Error: Unsupported platform $(uname -s), cannot auto-download cmake${NC}"
            return 1
            ;;
    esac

    local TARBALL="cmake-${CMAKE_VERSION}-${PLATFORM_SUFFIX}.tar.gz"
    local GITHUB_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${TARBALL}"

    # Mirror list: GitHub direct + ghfast.top proxy (China acceleration)
    local URLS=(
        "$GITHUB_URL"
	"https://cmake.org/files/v$(echo "$CMAKE_VERSION" | cut -d. -f1,2)/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"
    )

    mkdir -p "${DEPS_DIR}"
    local TMP_TARBALL="/tmp/${TARBALL}"

    local downloaded=0
    for url in "${URLS[@]}"; do
        echo -e ">>> Trying: ${BLUE}${url}${NC}"
        wget -c --timeout=30 --tries=2 -P /tmp "$url" 2>&1 | tail -3
        if [[ $? -eq 0 ]] && [[ -f "$TMP_TARBALL" ]]; then
            # Verify file size (should be ~55MB)
            local FILE_SIZE
            FILE_SIZE=$(stat -c%s "$TMP_TARBALL" 2>/dev/null || stat -f%z "$TMP_TARBALL" 2>/dev/null)
            if [[ "$FILE_SIZE" -gt 10000000 ]]; then
                echo ">>> Download successful (size: $((FILE_SIZE / 1024 / 1024))MB)"
                downloaded=1
                break
            else
                echo -e "${YELLOW}Warning: File too small ($FILE_SIZE bytes), trying next mirror${NC}"
                rm -f "$TMP_TARBALL"
            fi
        fi
    done

    if [[ $downloaded -eq 0 ]]; then
        echo -e "${RED}Error: cmake download failed (all mirrors unavailable)${NC}"
        echo -e "${RED}Please download manually: ${GITHUB_URL}${NC}"
        return 1
    fi

    # Extract to _deps/cmake/ (--strip-components=1 removes top-level cmake-X.Y.Z/ directory)
    echo ">>> Extracting to ${CMAKE_DIR}..."
    mkdir -p "$CMAKE_DIR"
    tar xzf "$TMP_TARBALL" -C "$CMAKE_DIR" --strip-components=1
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: cmake extraction failed${NC}"
        rm -rf "$CMAKE_DIR"
        rm -f "$TMP_TARBALL"
        return 1
    fi

    rm -f "$TMP_TARBALL"

    echo -e "${GREEN}=== cmake ${CMAKE_VERSION} ready: $CMAKE_DIR/bin/cmake ===${NC}"
    echo ""
}

download_libclang() {
    # Get clang major version from V8 source
    local V8_CLANG_UPDATE="${V8_SRC_DIR}/tools/clang/scripts/update.py"
    if [[ ! -f "$V8_CLANG_UPDATE" ]]; then
        echo -e "${RED}Error: V8 clang config file not found: $V8_CLANG_UPDATE${NC}"
        return 1
    fi

    local LIBCLANG_VERSION
    LIBCLANG_VERSION=$(grep "^RELEASE_VERSION" "$V8_CLANG_UPDATE" | sed -n "s/.*'\([0-9][0-9]*\).*/\1/p")
    if [[ -z "$LIBCLANG_VERSION" ]]; then
        echo -e "${RED}Error: Cannot extract clang version from V8${NC}"
        return 1
    fi

    # Check if this version of libclang already exists
    if [[ "$BD_FORCE" == "1" ]]; then
        rm -f "$CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so"* 2>/dev/null
        rm -f "$LIBCLANG_DEB" 2>/dev/null
    fi

    if [[ -f "$CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]]; then
        echo -e "${BLUE}libclang.so ready: $CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}${NC}"
    else
        ## Get latest libclang deb package URL for this version from apt.llvm.org
        ##local APT_INDEX_URL="https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"
        # Use TUNA mirror (apt.llvm.org may be slow in China)
        local APT_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"
        echo "=== Getting libclang-${LIBCLANG_VERSION} download link ==="
        # https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-21/
        # https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-21/
        echo -e "Index page: ${BLUE}${APT_INDEX_URL}${NC}"

        local LIBCLANG_URL
        LIBCLANG_URL=$(curl -s "$APT_INDEX_URL" | sed -n "s/.*href=\"\(libclang1-${LIBCLANG_VERSION}[^\"]*amd64\.deb\)\".*/\1/p" | tail -1)
        if [[ -z "$LIBCLANG_URL" ]]; then
            echo -e "${RED}Error: Cannot get libclang-${LIBCLANG_VERSION} package link from apt.llvm.org${NC}"
            return 1
        fi
        LIBCLANG_URL="${APT_INDEX_URL}${LIBCLANG_URL}"

        # https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-21/libclang1-21_21.1.5~%2B%2B20251023083255%2B45afac62e373-1~exp1~20251023083404.50_amd64.deb
        # https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-21/libclang1-21_21.1.1~%2B%2B20250908083503%2Bfa462a66e418-1~exp1~20250908083623.25_amd64.deb
        echo -e "Download URL: ${BLUE}${LIBCLANG_URL}${NC}"
        echo -e "Save path:    ${BLUE}${LIBCLANG_DEB}${NC}"

        # Download deb package (with retry and resume)
        for i in $(seq 1 $LIBCLANG_DOWNLOAD_RETRIES); do
            echo ">>> Downloading libclang1-${LIBCLANG_VERSION} package (~7MB)... (attempt $i/$LIBCLANG_DOWNLOAD_RETRIES)"
            # -C - supports resume, if file exists continue from breakpoint
            curl -L -C - --retry 3 --retry-delay 2 -o "$LIBCLANG_DEB" "$LIBCLANG_URL"
            if [[ $? -eq 0 ]]; then
                # Verify file size (should be ~7MB)
                local FILE_SIZE
                FILE_SIZE=$(stat -c%s "$LIBCLANG_DEB" 2>/dev/null || stat -f%z "$LIBCLANG_DEB" 2>/dev/null)
                if [[ "$FILE_SIZE" -gt 5000000 ]]; then
                    echo ">>> Download successful (size: $((FILE_SIZE / 1024))KB)"
                    break
                else
                    echo -e "${YELLOW}Warning: File too small ($FILE_SIZE bytes), possibly incomplete${NC}"
                    # Don't delete file, next attempt will resume
                fi
            fi
            if [[ $i -lt $LIBCLANG_DOWNLOAD_RETRIES ]]; then
                echo ">>> Retrying..."
                sleep 2
            fi
        done

        if [[ ! -f "$LIBCLANG_DEB" ]]; then
            echo -e "${RED}Error: libclang download failed (retried $LIBCLANG_DOWNLOAD_RETRIES times)${NC}"
            echo -e "${RED}Please check network or download manually: ${LIBCLANG_URL}${NC}"
            return 1
        fi

        # Extract to temp directory, get libclang.so
        echo ">>> Extracting libclang.so..."
        mkdir -p "$CLANG_DIR/lib"
        local LIBCLANG_EXTRACT_DIR
        LIBCLANG_EXTRACT_DIR=$(mktemp -d)
        dpkg-deb -x "$LIBCLANG_DEB" "$LIBCLANG_EXTRACT_DIR"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: libclang extraction failed${NC}"
            echo -e "${RED}Possible cause: Downloaded file corrupted, try deleting $LIBCLANG_DEB and retry${NC}"
            rm -rf "$LIBCLANG_EXTRACT_DIR"
            rm -f "$LIBCLANG_DEB"
            return 1
        fi

        # Copy libclang.so and create symlinks
        if [[ ! -f "$LIBCLANG_EXTRACT_DIR/usr/lib/x86_64-linux-gnu/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]]; then
            echo -e "${RED}Error: libclang-${LIBCLANG_VERSION}.so not found in deb package${NC}"
            rm -rf "$LIBCLANG_EXTRACT_DIR"
            return 1
        fi

        cp "$LIBCLANG_EXTRACT_DIR/usr/lib/x86_64-linux-gnu/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "$CLANG_DIR/lib/"
        rm -rf "$LIBCLANG_EXTRACT_DIR"
        rm -f "$LIBCLANG_DEB"
        echo -e "${GREEN}=== libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION} extracted ===${NC}"
    fi

    # libLLVM.so (runtime dependency of libclang, separate from libclang deb)
    if [[ ! -f "$CLANG_DIR/lib/libLLVM.so.${LIBCLANG_VERSION}.1" ]]; then
        local LLVM_DEB="/tmp/libllvm${LIBCLANG_VERSION}.deb"
        local APT_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"

        echo "=== Getting libllvm${LIBCLANG_VERSION} download link ==="
        local LLVM_URL
        LLVM_URL=$(curl -s "$APT_INDEX_URL" | sed -n "s/.*href=\"\(libllvm${LIBCLANG_VERSION}[^\"]*amd64\.deb\)\".*/\1/p" | tail -1)
        if [[ -z "$LLVM_URL" ]]; then
            echo -e "${RED}Error: Cannot get libllvm${LIBCLANG_VERSION} package link${NC}"
            return 1
        fi
        LLVM_URL="${APT_INDEX_URL}${LLVM_URL}"
        echo -e "Download URL: ${BLUE}${LLVM_URL}${NC}"

        for i in $(seq 1 $LIBCLANG_DOWNLOAD_RETRIES); do
            echo ">>> Downloading libllvm${LIBCLANG_VERSION} package... (attempt $i/$LIBCLANG_DOWNLOAD_RETRIES)"
            curl -L -C - --retry 3 --retry-delay 2 -o "$LLVM_DEB" "$LLVM_URL"
            if [[ $? -eq 0 ]] && [[ -f "$LLVM_DEB" ]]; then
                break
            fi
            [[ $i -lt $LIBCLANG_DOWNLOAD_RETRIES ]] && sleep 2
        done

        if [[ ! -f "$LLVM_DEB" ]]; then
            echo -e "${RED}Error: libllvm${LIBCLANG_VERSION} download failed${NC}"
            return 1
        fi

        echo ">>> Extracting libLLVM.so..."
        local LLVM_EXTRACT_DIR
        LLVM_EXTRACT_DIR=$(mktemp -d)
        dpkg-deb -x "$LLVM_DEB" "$LLVM_EXTRACT_DIR"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: libllvm extraction failed${NC}"
            rm -rf "$LLVM_EXTRACT_DIR"
            return 1
        fi

        local LLVM_LIB
        LLVM_LIB=$(find "$LLVM_EXTRACT_DIR" -name "libLLVM.so.${LIBCLANG_VERSION}.1" -print -quit)
        if [[ -z "$LLVM_LIB" ]]; then
            echo -e "${RED}Error: libLLVM.so.${LIBCLANG_VERSION}.1 not found in deb package${NC}"
            rm -rf "$LLVM_EXTRACT_DIR"
            return 1
        fi

        cp "$LLVM_LIB" "$CLANG_DIR/lib/"
        rm -rf "$LLVM_EXTRACT_DIR"
        rm -f "$LLVM_DEB"
        echo -e "${GREEN}=== libLLVM.so.${LIBCLANG_VERSION}.1 extracted ===${NC}"
    else
        echo -e "${BLUE}libLLVM.so ready: $CLANG_DIR/lib/libLLVM.so.${LIBCLANG_VERSION}.1${NC}"
    fi

    # Ensure symlinks exist
    pushd "$CLANG_DIR/lib" > /dev/null
    [[ -f "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]] && [[ ! -L "libclang.so.${LIBCLANG_VERSION}" ]] && ln -sf "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "libclang.so.${LIBCLANG_VERSION}"
    [[ -f "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]] && [[ ! -L "libclang.so" ]] && ln -sf "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "libclang.so"
    popd > /dev/null

    ls -lh "$CLANG_DIR/lib/libclang"*
}

# Create symlink in V8 tree at specified path pointing to cache
# Skip if path is already correct symlink; if old entity directory, migrate to cache first
# install-sysroot.py doesn't support custom output directory, so symlinks let V8 GN build
# find actual data under _deps/sysroots/
link_sysroot() {
    local v8_path="$1"    # Expected path inside V8 tree
    local cache_path="$2" # Cache path under _deps/sysroots/

    if [ -L "$v8_path" ]; then
        local current_target
        current_target=$(readlink "$v8_path")
        if [ "$current_target" = "$cache_path" ]; then
            return 0  # Symlink already correctly points to cache
        fi
        # Symlink points elsewhere, remove and recreate
        rm -f "$v8_path"
    fi

    # If old installation entity directory, migrate to cache (avoid re-download)
    if [ -d "$v8_path" ] && [ ! -d "$cache_path" ]; then
        echo ">>> Migrating existing sysroot to cache: $cache_path"
        mv "$v8_path" "$cache_path"
    elif [ -d "$v8_path" ]; then
        # Cache already exists, remove old entity directory
        rm -rf "$v8_path"
    fi

    _create_relative_symlink "$cache_path" "$v8_path"
}

# Ensure single sysroot is cached and symlink is established
# Args: $1=arch(arm64/amd64) $2=V8 tree path $3=cache path
#
# install-sysroot.py internally uses shutil.rmtree() to clean old directories—
# if V8 tree has a symlink, rmtree follows the link and deletes actual data in cache!
# So we must remove symlink first, let install-sysroot.py operate on cache directory, then recreate link.
ensure_sysroot() {
    local arch="$1"
    local v8_sysroot_path="$2"
    local cache_sysroot_path="$3"
    local label
    if [ "$arch" = "arm64" ]; then
        label="ARM64"
    else
        label="AMD64"
    fi

    # Fast path: cache complete + symlink correct → skip
    if [ -f "$cache_sysroot_path/usr/include/stdint.h" ] && [ -L "$v8_sysroot_path" ]; then
        local link_target
        link_target=$(readlink "$v8_sysroot_path")
        if [ "$link_target" = "$cache_sysroot_path" ]; then
            echo -e "${BLUE}${label} sysroot ready: $cache_sysroot_path${NC}"
            return 0
        fi
    fi

    echo "=== Processing ${label} sysroot ==="
    echo -e "Cache path: ${BLUE}${cache_sysroot_path}${NC}"

    mkdir -p "$cache_sysroot_path"

    # Handle old entity directory in V8 tree: migrate to cache (avoid re-download)
    # link_sysroot: if entity directory and cache empty → mv to cache; if cache has data → remove old directory
    link_sysroot "$v8_sysroot_path" "$cache_sysroot_path"

    # Download sysroot when cache is incomplete
    # At this point v8_sysroot_path is already a symlink, install-sysroot.py's rmtree follows link and deletes cache,
    # so we must remove symlink first, let install-sysroot.py operate on cache directory
    if [ ! -f "$cache_sysroot_path/usr/include/stdint.h" ]; then
        # Remove symlink to prevent install-sysroot.py's rmtree from following link and deleting cache content
        [ -L "$v8_sysroot_path" ] && rm -f "$v8_sysroot_path"

        ( cd "$V8_SRC_DIR" && python3 ./build/linux/sysroot_scripts/install-sysroot.py --arch="$arch" )
        if [ $? -ne 0 ]; then
            echo "Error: ${label} sysroot download failed"
            return 1
        fi

        # install-sysroot.py may replace cache directory with entity directory (rmtree + mkdir),
        # if V8 tree path is now entity directory instead of symlink, move it to cache and recreate link
        if [ -d "$v8_sysroot_path" ] && [ ! -L "$v8_sysroot_path" ]; then
            rm -rf "$cache_sysroot_path"
            mv "$v8_sysroot_path" "$cache_sysroot_path"
            _create_relative_symlink "$cache_sysroot_path" "$v8_sysroot_path"
        fi
    else
        # Cache complete, ensure symlink exists
        if [ ! -L "$v8_sysroot_path" ]; then
            _create_relative_symlink "$cache_sysroot_path" "$v8_sysroot_path"
        fi
    fi

    echo "=== ${label} sysroot processing complete ==="
    echo ""
}

download_sysroot() {
    # Expected paths in V8 tree (install-sysroot.py installation targets)
    local V8_LINUX_DIR="${V8_SRC_DIR}/build/linux"
    local V8_ARM64_SYSROOT="${V8_LINUX_DIR}/debian_bullseye_arm64-sysroot"
    local V8_AMD64_SYSROOT="${V8_LINUX_DIR}/debian_bullseye_amd64-sysroot"

    # Pre-check: sysroot needs to create symlinks inside V8 source tree, V8 directory must exist
    if [ ! -d "$V8_LINUX_DIR" ]; then
        echo "Error: V8 source directory not found: $V8_LINUX_DIR"
        echo "Please run cargo vendor first, or remove --skip-vendor flag"
        return 1
    fi

    # --force cleanup: remove both cache and symlinks in V8 tree
    if [[ "$BD_FORCE" == "1" ]]; then
        if [[ -d "$SYSROOT_CACHE_DIR" ]]; then
            echo "=== [--force] Removing sysroot cache: $SYSROOT_CACHE_DIR ==="
            rm -rf "$SYSROOT_CACHE_DIR"
        fi
        # Clean up leftover symlinks or directories in V8 tree
        [ -e "$V8_ARM64_SYSROOT" ] || [ -L "$V8_ARM64_SYSROOT" ] && rm -rf "$V8_ARM64_SYSROOT"
        [ -e "$V8_AMD64_SYSROOT" ] || [ -L "$V8_AMD64_SYSROOT" ] && rm -rf "$V8_AMD64_SYSROOT"
    fi

    mkdir -p "$SYSROOT_CACHE_DIR"

    # Download ARM64 sysroot (used by TARGET v8 build)
    ensure_sysroot "arm64" "$V8_ARM64_SYSROOT" "$SYSROOT_CACHE_DIR/debian_bullseye_arm64-sysroot" || return 1

    # Download AMD64 sysroot (used by HOST v8 build: obscura-js build-dependencies triggers x86_64 v8 compilation)
    # Must pre-download here, otherwise cargo parallel build runs HOST v8 before TARGET v8,
    # can't find glib-2.0 causing gn gen failure
    ensure_sysroot "amd64" "$V8_AMD64_SYSROOT" "$SYSROOT_CACHE_DIR/debian_bullseye_amd64-sysroot" || return 1
}

create_cargo_configs() {
    echo "=== Creating cargo config files ==="

    # Create mirror config (used during vendor phase)
    cat > "$CARGO_CONFIG_VENDOR" << 'EOF'
[env]
RUST_TEST_THREADS = "1"

# macOS 26 (Tahoe) moved libc++ headers inside the SDK; Apple clang 17 no longer
# finds them at the old search path. This causes boring-sys's cmake step to fail
# when building with --features stealth. Setting CXXFLAGS and SDKROOT here makes
# them visible to all build scripts (including boring-sys's) so cmake can locate
# the headers. force=false lets CI or developers override via their shell env.
# Non-macOS platforms ignore SDKROOT; the -isystem path is silently skipped if
# it doesn't exist. See: https://github.com/h4ckf0r0day/obscura/issues/136
#CXXFLAGS = { value = "-isystem /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1", force = false }
#SDKROOT  = { value = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk", force = false }

[http]
timeout = 600

[source.crates-io]
replace-with = 'ustc'

[source.ustc]
registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"
EOF

    # Create vendor config (used during build phase)
    cat > "$CARGO_CONFIG_BUILD" << 'EOF'
[env]
RUST_TEST_THREADS = "1"

# macOS 26 (Tahoe) moved libc++ headers inside the SDK; Apple clang 17 no longer
# finds them at the old search path. This causes boring-sys's cmake step to fail
# when building with --features stealth. Setting CXXFLAGS and SDKROOT here makes
# them visible to all build scripts (including boring-sys's) so cmake can locate
# the headers. force=false lets CI or developers override via their shell env.
# Non-macOS platforms ignore SDKROOT; the -isystem path is silently skipped if
# it doesn't exist. See: https://github.com/h4ckf0r0day/obscura/issues/136
#CXXFLAGS = { value = "-isystem /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1", force = false }
#SDKROOT  = { value = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk", force = false }

[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "third_party"
EOF

    echo "  $CARGO_CONFIG_VENDOR"
    echo "  $CARGO_CONFIG_BUILD"
}

run_vendor() {
    echo "=== cargo vendor (using China mirror) ==="
    cp "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG"
    echo "cargo vendor --versioned-dirs third_party --locked"
    cargo vendor --versioned-dirs third_party --locked
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "cargo vendor failed, exit code: $exit_code"
        cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"
        return $exit_code
    fi
    echo "=== cargo vendor complete ==="
}

# ===================== Help =====================

bd_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Download all dependencies for Obscura cross-compilation (x86_64 → aarch64)."
    echo ""
    echo "Options:"
    echo "  --skip-clang       Skip clang download"
    echo "  --skip-ninja-gn    Skip ninja/gn download"
    echo "  --skip-libclang    Skip libclang.so download"
    echo "  --skip-sysroot     Skip ARM64 sysroot download"
    echo "  --skip-cmake       Skip cmake download (needed for --features stealth)"
    echo "  --skip-vendor      Skip cargo vendor"
    echo "  --vendor-only      Only run cargo vendor (skip all other downloads)"
    echo "  --force            Force re-download of existing files"
    echo "  -h, --help         Show help"
    echo ""
    echo "Examples:"
    echo "  $0                         # Download everything"
    echo "  $0 --vendor-only           # Only run cargo vendor"
    echo "  $0 --skip-vendor           # Download clang/ninja_gn/libclang/sysroot, skip vendor"
    echo "  $0 --skip-ninja-gn         # Download clang/libclang/sysroot, skip ninja/gn"
    echo "  $0 --force --skip-vendor   # Force re-download clang/libclang/sysroot"
    echo ""
    echo "Sourced by other scripts:"
    echo "  source ./_scripts/build_download.sh  # Get variables and functions, no download"
    exit 0
}

# ===================== Standalone Execution Logic =====================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BD_SKIP_CLANG=0
    BD_SKIP_NINJA_GN=0
    BD_SKIP_LIBCLANG=0
    BD_SKIP_SYSROOT=0
    BD_SKIP_CMAKE=0
    BD_SKIP_VENDOR=0
    BD_VENDOR_ONLY=0
    BD_FORCE=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-clang)      BD_SKIP_CLANG=1; shift ;;
            --skip-ninja-gn)   BD_SKIP_NINJA_GN=1; shift ;;
            --skip-libclang)   BD_SKIP_LIBCLANG=1; shift ;;
            --skip-sysroot)    BD_SKIP_SYSROOT=1; shift ;;
            --skip-cmake)      BD_SKIP_CMAKE=1; shift ;;
            --skip-vendor)     BD_SKIP_VENDOR=1; shift ;;
            --vendor-only)     BD_VENDOR_ONLY=1; shift ;;
            --force)           BD_FORCE=1; shift ;;
            -h|--help)         bd_usage ;;
            *)
                echo "Unknown option: $1"
                bd_usage
                ;;
        esac
    done

    echo "=== build_download.sh started: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
    echo "  FORCE=$BD_FORCE  VENDOR_ONLY=$BD_VENDOR_ONLY"
    echo ""

    cd "$OBSCURA_DIR"

    if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
        create_cargo_configs
        run_vendor || exit 1
    else
        [[ "$BD_SKIP_CLANG"    -eq 0 ]] && download_clang       || echo ">>> Skipping clang download"
        [[ "$BD_SKIP_NINJA_GN" -eq 0 ]] && download_ninja_gn    || echo ">>> Skipping ninja/gn download"
        [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && download_libclang    || echo ">>> Skipping libclang download"
        # cargo vendor must run before sysroot: sysroot needs to create symlinks in V8 source tree
        if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
            create_cargo_configs
            run_vendor || exit 1
        else
            echo ">>> Skipping cargo vendor"
        fi
        [[ "$BD_SKIP_SYSROOT"  -eq 0 ]] && download_sysroot     || echo ">>> Skipping sysroot download"
        [[ "$BD_SKIP_CMAKE"   -eq 0 ]] && download_cmake        || echo ">>> Skipping cmake download"
    fi

    echo ""
    echo "=== build_download.sh completed: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
fi
