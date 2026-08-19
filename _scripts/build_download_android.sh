#!/bin/bash
# ============================================================
# build_download_android.sh - Download Android cross-compilation build dependencies
#
# Extends build_download.sh with Android-specific dependencies (NDK, catapult)
# and Rust standard library for android target
#
# android_platform is not needed: standalone V8 build doesn't reference it
# (see build/android/BUILD.gn:260-261, only triggered by build_with_chromium)
#
# Usage:
#   Standalone: ./build_download_android.sh [options]
#   Sourced:    source ./build_download_android.sh  (get variables and functions, no download)
#
# Options:
#   Same as build_download.sh, plus:
#   --skip-android-ndk      Skip Android NDK download
#   --skip-android-repos    Skip catapult clone
#   --skip-android-stdlib   Skip Android Rust stdlib download
# ============================================================

[[ -n "$_BUILD_DOWNLOAD_ANDROID_LOADED" ]] && return 0 2>/dev/null
_BUILD_DOWNLOAD_ANDROID_LOADED=1

source "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/build_download.sh"

# ===================== Android-specific Variables =====================
ANDROID_DEPS_DIR="${DEPS_DIR}/android"

# NDK version extracted from V8 build.rs, fallback to r26c on failure
_extract_ndk_ver() {
    if [ -f "${V8_SRC_DIR}/build.rs" ]; then
        grep -oE 'android-ndk-(r[a-z0-9]+-linux)\.zip' "${V8_SRC_DIR}/build.rs" | head -1 | sed -n 's/.*\(r[a-z0-9]*\)-linux.*/\1/p'
    fi
}
NDK_VER=$(_extract_ndk_ver)
NDK_VER="${NDK_VER:-r26c}"
ANDROID_NDK_DIR="${ANDROID_DEPS_DIR}/ndk-${NDK_VER}"
NDK_API_LEVEL=24
ANDROID_NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"
ANDROID_NDK_ZIP="/tmp/android-ndk-${NDK_VER}-linux.zip"

CATAPULT_DIR="${ANDROID_DEPS_DIR}/catapult"
CATAPULT_REPO="https://chromium.googlesource.com/catapult.git"

# Path inside V8 crate that needs symlinks (relative to V8 source root)
V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"

# zip extraction helper: prefer unzip (natively preserves symlinks), fallback to Python zipfile
# Python zipfile fallback detects Unix symlink markers in ZIP and rebuilds them manually
# Post-fix step as safety net ensures all symlinks and permissions under NDK bin/ are correct
_extract_zip() {
    local zip_file="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"
    if command -v unzip &>/dev/null; then
        unzip -q -o "$zip_file" -d "$dest_dir"
        echo ">>> Extracted with unzip (native symlink support)"
    elif command -v python3 &>/dev/null; then
        # Python zipfile doesn't auto-create symlinks, need to detect and rebuild manually
        # Pass paths via environment variables to avoid shell inline relative path/special char issues
        EXTRACT_ZIP_FILE="$zip_file" EXTRACT_DEST_DIR="$dest_dir" python3 -c "
import zipfile, os, stat

zip_file = os.environ['EXTRACT_ZIP_FILE']
dest_dir = os.path.abspath(os.environ['EXTRACT_DEST_DIR'])

with zipfile.ZipFile(zip_file, 'r') as z:
    for info in z.infolist():
        # Unix symlink: external_attr upper 16 bits contain S_IFLNK flag
        unix_mode = info.external_attr >> 16
        is_symlink = stat.S_ISLNK(unix_mode) if unix_mode else False
        target_path = os.path.join(dest_dir, info.filename)
        if is_symlink:
            # Symlink target path stored in zip file content (relative names in same dir for NDK)
            link_target = z.read(info.filename).decode('utf-8', errors='surrogateescape')
            os.makedirs(os.path.dirname(target_path), exist_ok=True)
            if os.path.lexists(target_path):
                os.remove(target_path)
            os.symlink(link_target, target_path)
        else:
            z.extract(info, dest_dir)
"
        echo ">>> Extracted with python3 (symlinks rebuilt)"
    else
        echo -e "${RED}Error: Neither unzip nor python3 found, cannot extract zip${NC}" >&2
        echo -e "${RED}Please install unzip: apt install unzip${NC}" >&2
        return 1
    fi
    # Supplementary fix: ensure all files under NDK bin/ are executable, fix symlinks corrupted by zip/py
    for ext_dir in "${dest_dir}"/android-ndk-*/; do
        local bin_dir="${ext_dir}toolchains/llvm/prebuilt/linux-x86_64/bin"
        if [ -d "$bin_dir" ]; then
            chmod +x "$bin_dir"/*
            cd "$bin_dir" || continue
            [ -f clang-17 ] && [ ! -L clang ] && ln -sf clang-17 clang 2>/dev/null
            [ -L clang ] && [ ! -L clang++ ] && ln -sf clang clang++ 2>/dev/null
            [ -f lld ] && [ ! -L ld.lld ] && ln -sf lld ld.lld 2>/dev/null
            [ -f lld ] && [ ! -L ld64.lld ] && ln -sf lld ld64.lld 2>/dev/null
            [ -f llvm-ar ] && [ ! -L ar ] && ln -sf llvm-ar ar 2>/dev/null
            [ -f llvm-objcopy ] && [ ! -L objcopy ] && ln -sf llvm-objcopy objcopy 2>/dev/null
            [ -f llvm-nm ] && [ ! -L nm ] && ln -sf llvm-nm nm 2>/dev/null
            [ -f llvm-strip ] && [ ! -L strip ] && ln -sf llvm-strip strip 2>/dev/null
            [ -f llvm-ranlib ] && [ ! -L ranlib ] && ln -sf llvm-ranlib ranlib 2>/dev/null
            # Generic fix: Python zipfile turns symlinks into small text files containing target names
            # Detect and fix all such corrupted "fake symlinks"
            local _fixed=0
            for f in *; do
                [ -L "$f" ] && continue      # Already a symlink, skip
                [ -f "$f" ] || continue      # Not a regular file, skip
                local sz
                sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
                [ "$sz" -ge 64 ] && continue # Normal binary >= 64 bytes, skip
                local target
                target=$(cat "$f" 2>/dev/null | tr -d '\0')
                # If file content (after removing null bytes) is another file in same dir, it's a broken symlink
                if [ -n "$target" ] && [ -e "$target" ]; then
                    rm -f "$f"
                    ln -sf "$target" "$f"
                    _fixed=$((_fixed + 1))
                fi
            done
            cd - > /dev/null
            echo ">>> Fixed NDK binary permissions and symlinks (generic fix: ${_fixed} items)"
        fi
    done
}

# ===================== Android Download Functions =====================

download_android_stdlib() {
    local TARGET_TRIPLE="${1:-aarch64-linux-android}"
    local LOCAL_VERSION
    if [ -z "$RUST_DIR" ] || [ ! -x "$RUST_DIR/rustc/bin/rustc" ]; then
        echo -e "${RED}Error: Rust toolchain not ready, please run download_rust_toolchain first${NC}"
        return 1
    fi
    LOCAL_VERSION=$(basename "$RUST_DIR" | sed -n 's/.*rust-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$LOCAL_VERSION" ]; then
        echo -e "${RED}Error: Cannot extract Rust version from $RUST_DIR${NC}"
        return 1
    fi

    if [[ "$BD_FORCE" == "1" ]]; then
        rm -rf "${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}"
    fi

    if [ -d "${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}" ]; then
        echo -e "${BLUE}Android Rust stdlib ready: ${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE}${NC}"
        return 0
    fi

    echo "=== Downloading Android Rust standard library (${TARGET_TRIPLE}) ==="

    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML="/tmp/channel-rust-stable-android.toml"

    echo -e "Downloading channel manifest: ${BLUE}${CHANNEL_URL}${NC}"
    wget -q --timeout=10 -O "$CHANNEL_TOML" "$CHANNEL_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to download channel manifest${NC}"
        return 1
    fi

    local STD_URL
    STD_URL=$(awk '/^\[pkg\.rust-std\.target\.'"${TARGET_TRIPLE//./\\.}"'\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")
    rm -f "$CHANNEL_TOML"

    if [ -z "$STD_URL" ]; then
        echo -e "${RED}Error: Cannot find ${TARGET_TRIPLE} stdlib URL${NC}"
        return 1
    fi

    local CHANNEL_VERSION
    CHANNEL_VERSION=$(echo "$STD_URL" | sed -n 's/.*rust-std-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    echo -e "Local Rust:      ${BLUE}${LOCAL_VERSION}${NC}"
    echo -e "Channel version: ${BLUE}${CHANNEL_VERSION}${NC}"
    echo -e "Stdlib URL:      ${BLUE}${STD_URL}${NC}"

    if [ "$LOCAL_VERSION" != "$CHANNEL_VERSION" ]; then
        echo -e "${YELLOW}Warning: Channel version (${CHANNEL_VERSION}) differs from local toolchain (${LOCAL_VERSION})${NC}"
        echo -e "${YELLOW}         stdlib version must match rustc exactly, trying to download matching version from official Rust mirror...${NC}"
        local DOWNLOAD_DATE
        DOWNLOAD_DATE=$(echo "$STD_URL" | sed -n 's/.*dist\/\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p')
        if [ -n "$DOWNLOAD_DATE" ]; then
            STD_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/rust-std-${LOCAL_VERSION}-${TARGET_TRIPLE}.tar.gz"
            echo -e "Trying version-matched URL: ${BLUE}${STD_URL}${NC}"
        fi
    fi

    local STD_TARBALL="/tmp/rust-std-android.tar.gz"
    echo ">>> Downloading Android stdlib..."
    rm -f "$STD_TARBALL"
    wget -c --timeout=30 --tries=2 -O "$STD_TARBALL" "$STD_URL"

    if [ $? -ne 0 ] || [ ! -f "$STD_TARBALL" ]; then
        echo -e "${YELLOW}Warning: Primary URL download failed, trying static.rust-lang.org...${NC}"
        rm -f "$STD_TARBALL"
        local FALLBACK_URL="https://static.rust-lang.org/dist/rust-std-${LOCAL_VERSION}-${TARGET_TRIPLE}.tar.gz"
        echo -e "Fallback URL: ${BLUE}${FALLBACK_URL}${NC}"
        wget -c --timeout=30 --tries=2 -O "$STD_TARBALL" "$FALLBACK_URL"
        if [ $? -ne 0 ] || [ ! -f "$STD_TARBALL" ]; then
            echo -e "${RED}Error: All Android stdlib download URLs failed${NC}"
            return 1
        fi
    fi

    local FILE_SIZE
    FILE_SIZE=$(stat -c%s "$STD_TARBALL" 2>/dev/null || stat -f%z "$STD_TARBALL" 2>/dev/null)
    if [[ "$FILE_SIZE" -lt 1000000 ]]; then
        echo -e "${RED}Error: Android stdlib file too small (${FILE_SIZE} bytes)${NC}"
        rm -f "$STD_TARBALL"
        return 1
    fi

    echo ">>> Extracting and adding to Rust toolchain..."
    local EXTRACT_DIR="/tmp/rust-std-android-extract"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    tar xzf "$STD_TARBALL" -C "$EXTRACT_DIR"

    local STD_LIB_DIR
    STD_LIB_DIR=$(find "$EXTRACT_DIR" -type d -name "${TARGET_TRIPLE}" -path "*/lib/rustlib/*" -print -quit)
    if [ -z "$STD_LIB_DIR" ]; then
        STD_LIB_DIR=$(find "$EXTRACT_DIR" -type d -name "${TARGET_TRIPLE}" -print -quit)
    fi
    if [ -z "$STD_LIB_DIR" ]; then
        echo -e "${RED}Error: ${TARGET_TRIPLE} stdlib not found after extraction${NC}"
        rm -rf "$EXTRACT_DIR"
        return 1
    fi

    cp -ar "$STD_LIB_DIR" "${RUST_DIR}/rustc/lib/rustlib/"
    rm -rf "$EXTRACT_DIR"
    rm -f "$STD_TARBALL"

    echo -e "${GREEN}=== Android Rust stdlib ready: ${RUST_DIR}/rustc/lib/rustlib/${TARGET_TRIPLE} ===${NC}"
    echo ""
}

download_android_ndk() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$ANDROID_NDK_DIR" ]]; then
        echo "=== [--force] Removing existing Android NDK: $ANDROID_NDK_DIR ==="
        rm -rf "$ANDROID_NDK_DIR"
    fi

    if [ -f "${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${NDK_API_LEVEL}-clang++" ]; then
        echo -e "${BLUE}Android NDK r26c ready: $ANDROID_NDK_DIR${NC}"
        return 0
    fi

    echo "=== Downloading Android NDK r26c ==="
    echo -e "URL:  ${BLUE}${ANDROID_NDK_URL}${NC}"
    echo -e "Path: ${BLUE}${ANDROID_NDK_DIR}${NC}"

    mkdir -p "${ANDROID_DEPS_DIR}"

    if [ ! -f "$ANDROID_NDK_ZIP" ]; then
        echo ">>> Downloading NDK zip (~500MB)..."
        wget -c --timeout=60 --tries=3 -O "$ANDROID_NDK_ZIP" "$ANDROID_NDK_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Android NDK download failed${NC}"
            echo -e "${RED}Please check network or download manually to: ${ANDROID_NDK_ZIP}${NC}"
            return 1
        fi
    else
        echo ">>> Using cached NDK zip: $ANDROID_NDK_ZIP"
    fi

    local FILE_SIZE
    FILE_SIZE=$(stat -c%s "$ANDROID_NDK_ZIP" 2>/dev/null || stat -f%z "$ANDROID_NDK_ZIP" 2>/dev/null)
    if [[ "$FILE_SIZE" -lt 100000000 ]]; then
        echo -e "${RED}Error: NDK zip file too small (${FILE_SIZE} bytes), possibly incomplete download${NC}"
        rm -f "$ANDROID_NDK_ZIP"
        return 1
    fi

    echo ">>> Extracting NDK to ${ANDROID_DEPS_DIR}..."
    _extract_zip "$ANDROID_NDK_ZIP" "${ANDROID_DEPS_DIR}/"

    local EXTRACTED_DIR="${ANDROID_DEPS_DIR}/android-ndk-r26c"
    if [ ! -d "$EXTRACTED_DIR" ]; then
        echo -e "${RED}Error: NDK extraction failed, android-ndk-r26c directory not found${NC}"
        return 1
    fi

    # If target is already a directory with same name, move contents instead of renaming
    if [ "$EXTRACTED_DIR" != "$ANDROID_NDK_DIR" ]; then
        mv "$EXTRACTED_DIR" "$ANDROID_NDK_DIR"
    fi

    rm -f "$ANDROID_NDK_ZIP"

    echo -e "${GREEN}=== Android NDK r26c ready: $ANDROID_NDK_DIR ===${NC}"
    echo ""
}

download_catapult() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CATAPULT_DIR" ]]; then
        echo "=== [--force] Removing existing catapult: $CATAPULT_DIR ==="
        rm -rf "$CATAPULT_DIR"
    fi

    if [ -d "${CATAPULT_DIR}/.git" ]; then
        echo -e "${BLUE}catapult ready: $CATAPULT_DIR${NC}"
        return 0
    fi

    echo "=== Cloning catapult ==="
    echo -e "Repo: ${BLUE}${CATAPULT_REPO}${NC}"
    echo -e "Path: ${BLUE}${CATAPULT_DIR}${NC}"

    mkdir -p "${ANDROID_DEPS_DIR}"
    git clone --depth=1 "$CATAPULT_REPO" "$CATAPULT_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: catapult clone failed${NC}"
        return 1
    fi

    echo -e "${GREEN}=== catapult ready: $CATAPULT_DIR ===${NC}"
    echo ""
}

create_android_v8_symlinks() {
    if [ ! -d "$V8_THIRD_PARTY_DIR" ]; then
        echo -e "${YELLOW}Warning: V8 third_party directory missing: $V8_THIRD_PARTY_DIR (cargo vendor not run yet?)${NC}"
        return 1
    fi

    echo "=== Creating V8 → Android dependency symlinks ==="

    # android_ndk symlink
    # V8 build.rs checks if ./third_party/android_ndk/... exists, skips download if so
    local V8_NDK_LINK="${V8_THIRD_PARTY_DIR}/android_ndk"
    if [ -L "$V8_NDK_LINK" ]; then
        local current_target
        current_target=$(readlink "$V8_NDK_LINK")
        if [ "$current_target" = "$ANDROID_NDK_DIR" ]; then
            echo -e "${BLUE}android_ndk symlink ready: $V8_NDK_LINK${NC}"
        else
            rm -f "$V8_NDK_LINK"
            _create_relative_symlink "$ANDROID_NDK_DIR" "$V8_NDK_LINK"
        fi
    elif [ -d "$V8_NDK_LINK" ]; then
        echo ">>> Existing android_ndk directory in V8, skipping"
    else
        _create_relative_symlink "$ANDROID_NDK_DIR" "$V8_NDK_LINK"
    fi

    # android_platform: standalone V8 doesn't need content, but V8 build.rs checks path existence
    # If missing, it tries git clone (fails offline). Keep empty dir as placeholder.
    local V8_AP_LINK="${V8_THIRD_PARTY_DIR}/android_platform"
    local AP_DIR="${ANDROID_DEPS_DIR}/android_platform"
    mkdir -p "$AP_DIR"
    if [ ! -L "$V8_AP_LINK" ] && [ ! -d "$V8_AP_LINK" ]; then
        _create_relative_symlink "$AP_DIR" "$V8_AP_LINK"
    fi

    # catapult symlink
    local V8_CT_LINK="${V8_THIRD_PARTY_DIR}/catapult"
    if [ -L "$V8_CT_LINK" ]; then
        local current_target
        current_target=$(readlink "$V8_CT_LINK")
        if [ "$current_target" != "$CATAPULT_DIR" ]; then
            rm -f "$V8_CT_LINK"
            _create_relative_symlink "$CATAPULT_DIR" "$V8_CT_LINK"
        else
            echo -e "${BLUE}catapult symlink ready: $V8_CT_LINK${NC}"
        fi
    elif [ -d "$V8_CT_LINK" ]; then
        echo ">>> Existing catapult directory in V8, skipping"
    else
        _create_relative_symlink "$CATAPULT_DIR" "$V8_CT_LINK"
    fi

    echo ""
}

# ===================== Help =====================

bd_android_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Download all dependencies for Obscura Android cross-compilation (x86_64 → aarch64-linux-android)."
    echo ""
    echo "Base options (same as build_download.sh):"
    echo "  --skip-clang       Skip clang download"
    echo "  --skip-rust        Skip Rust toolchain download"
    echo "  --skip-ninja-gn    Skip ninja/gn download"
    echo "  --skip-libclang    Skip libclang.so download"
    echo "  --skip-sysroot     Skip Debian sysroot download (not needed for Android)"
    echo "  --skip-cmake       Skip cmake download (needed for --features stealth)"
    echo "  --skip-vendor      Skip cargo vendor"
    echo "  --vendor-only      Only run cargo vendor (skip all other downloads)"
    echo "  --force            Force re-download of existing files"
    echo ""
    echo "Android-specific options:"
    echo "  --skip-android-ndk     Skip Android NDK download"
    echo "  --skip-android-repos   Skip catapult clone"
    echo "  --skip-android-stdlib  Skip Android Rust stdlib download"
    echo ""
    echo "  -h, --help         Show help"
    echo ""
    echo "Examples:"
    echo "  $0                                     # Download everything"
    echo "  $0 --vendor-only                       # Only run cargo vendor"
    echo "  $0 --skip-android-ndk                  # Skip NDK (use existing NDK)"
    echo "  $0 --force                             # Force re-download everything"
    exit 0
}

# ===================== Standalone Execution Logic =====================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BD_SKIP_RUST=0
    BD_SKIP_CLANG=0
    BD_SKIP_NINJA_GN=0
    BD_SKIP_LIBCLANG=0
    BD_SKIP_SYSROOT=1        # Android doesn't need Debian sysroot
    BD_SKIP_CMAKE=0
    BD_SKIP_VENDOR=0
    BD_VENDOR_ONLY=0
    BD_FORCE=0
    BD_SKIP_ANDROID_NDK=0
    BD_SKIP_ANDROID_REPOS=0
    BD_SKIP_ANDROID_STDLIB=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-clang)            BD_SKIP_CLANG=1; shift ;;
            --skip-rust)             BD_SKIP_RUST=1; shift ;;
            --skip-ninja-gn)         BD_SKIP_NINJA_GN=1; shift ;;
            --skip-libclang)         BD_SKIP_LIBCLANG=1; shift ;;
            --skip-sysroot)          BD_SKIP_SYSROOT=1; shift ;;
            --skip-cmake)            BD_SKIP_CMAKE=1; shift ;;
            --skip-vendor)           BD_SKIP_VENDOR=1; shift ;;
            --vendor-only)           BD_VENDOR_ONLY=1; shift ;;
            --force)                 BD_FORCE=1; shift ;;
            --skip-android-ndk)      BD_SKIP_ANDROID_NDK=1; shift ;;
            --skip-android-repos)    BD_SKIP_ANDROID_REPOS=1; shift ;;
            --skip-android-stdlib)   BD_SKIP_ANDROID_STDLIB=1; shift ;;
            -h|--help)               bd_android_usage ;;
            *)
                echo "Unknown option: $1"
                bd_android_usage
                ;;
        esac
    done

    echo "=== build_download_android.sh started: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
    echo "  FORCE=$BD_FORCE  VENDOR_ONLY=$BD_VENDOR_ONLY"
    echo ""

    cd "$OBSCURA_DIR"

    if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
        create_cargo_configs
        run_vendor || exit 1
    else
        # 1. Rust toolchain (with Android stdlib)
        [[ "$BD_SKIP_RUST" -eq 0 ]] && download_rust_toolchain || echo ">>> Skipping Rust toolchain download"
        # Set up Rust environment first, needed for subsequent cargo vendor
        export RUST_DIR="${RUST_DIR}"
        if [ -n "$RUST_DIR" ] && [ -x "$RUST_DIR/rustc/bin/rustc" ]; then
            export RUSTC="$RUST_DIR/rustc/bin/rustc"
            export CARGO="$RUST_DIR/cargo/bin/cargo"
            export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"
        fi

        # 2. cargo vendor
        if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
            create_cargo_configs
            run_vendor || exit 1
            # Re-scan V8_SRC_DIR after vendor
            V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
            V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"
        else
            echo ">>> Skipping cargo vendor"
        fi

        # 3. clang
        [[ "$BD_SKIP_CLANG" -eq 0 ]] && download_clang || echo ">>> Skipping clang download"

        # 4. ninja/gn
        [[ "$BD_SKIP_NINJA_GN" -eq 0 ]] && download_ninja_gn || echo ">>> Skipping ninja/gn download"

        # 5. libclang
        [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && download_libclang || echo ">>> Skipping libclang download"

        # 6. cmake
        [[ "$BD_SKIP_CMAKE" -eq 0 ]] && download_cmake || echo ">>> Skipping cmake download"

        # 7. Android Rust stdlib
        if [[ "$BD_SKIP_ANDROID_STDLIB" -eq 0 ]]; then
            download_android_stdlib "aarch64-linux-android" || echo -e "${YELLOW}Warning: aarch64 stdlib download failed${NC}"
            download_android_stdlib "x86_64-linux-android" || echo -e "${YELLOW}Warning: x86_64 stdlib download failed${NC}"
        else
            echo ">>> Skipping Android Rust stdlib download"
        fi

        # 8. Android NDK
        if [[ "$BD_SKIP_ANDROID_NDK" -eq 0 ]]; then
            download_android_ndk || exit 1
        else
            echo ">>> Skipping Android NDK download"
        fi

        # 9. catapult (android_platform not needed, see file header comment)
        if [[ "$BD_SKIP_ANDROID_REPOS" -eq 0 ]]; then
            download_catapult || echo -e "${YELLOW}Warning: catapult download failed${NC}"
        else
            echo ">>> Skipping catapult download"
        fi

        # 10. Create symlinks inside V8 tree (so build.rs skips its own downloads)
        create_android_v8_symlinks || echo -e "${YELLOW}Warning: Symlink creation failed (doesn't affect first build after cargo vendor)${NC}"
    fi

    echo ""
    echo "=== build_download_android.sh completed: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
fi
