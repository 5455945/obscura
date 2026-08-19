#!/bin/bash

echo "begin time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"

# ===================== Resolve Project Root (realpath handles symlinks cross-platform) =====================
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# ===================== Ensure build.sh symlink in project root =====================
if [[ ! -L "${OBSCURA_DIR}/build.sh" ]]; then
    ln -sf "_scripts/build.sh" "${OBSCURA_DIR}/build.sh"
    echo "Created symlink: ${OBSCURA_DIR}/build.sh -> _scripts/build.sh"
fi

# ===================== Import Download Module =====================
source "$OBSCURA_DIR/_scripts/build_download.sh"

# ===================== Build Argument Parsing =====================
BUILD_MODE="--release"
TARGET_ARCH="aarch64"               # Target architecture: aarch64 (default) or x86_64
TARGET_DIR=""                       # Auto-set based on architecture
TARGET_LINK=""                      # Rust target triple, auto-set based on architecture
#CARGO_EXTRA_ARGS="-j20 -vv"
CARGO_EXTRA_ARGS="-j20 -v"
DO_CLEAN=0
BUILD_REQUESTED=0
MODE_EXPLICIT=0   # Whether --debug or --release was explicitly specified
ARCH_EXPLICIT=0   # Whether --arch was explicitly specified
STEALTH_FEATURE=1 # stealth feature enabled by default (anti-detection + tracker blocking)


usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Build options:"
    echo "  --release           Build release version (default)"
    echo "  --debug             Build debug version"
    echo "  --arch ARCH         Target architecture: aarch64 (default) or x86_64"
    echo "  --target-dir DIR    Specify build output directory (default: ./target/<arch>)"
    echo "  --cargo-args ARGS   Extra arguments passed to cargo build (default: \"-j20 -vv\")"
    echo "                      e.g.: \"-j8 -vv\" or \"-j32\""
    echo "                      e.g.: \"--features render\" to enable render feature"
    echo "                      e.g.: \"--no-default-features\" to disable all default features"
    echo "                      e.g.: \"--features render,stealth\" to enable multiple features"
    echo "                      e.g.: \"--no-default-features --features stealth\" to enable only stealth"
    echo ""
    echo "Download options (passed through to build_download.sh):"
    echo "  --skip-clang        Skip clang download"
    echo "  --skip-rust         Skip Rust cross-compilation toolchain download"
    echo "  --skip-ninja-gn     Skip ninja/gn download"
    echo "  --skip-libclang     Skip libclang download"
    echo "  --skip-sysroot      Skip sysroot download"
    echo "  --skip-cmake        Skip cmake download (needed for stealth mode, enabled by default)"
    echo "  --skip-vendor       Skip cargo vendor"
    echo "  --vendor-only       Only run cargo vendor"
    echo "  --force             Force re-download of existing files"
    echo ""
    echo "Other options:"
    echo "  --examples          Also build V8 example programs (hello_world, shell, process, etc.)"
    echo "  --package           Create tar.gz package after build (strip compressed binaries + README + LICENSE)"
    echo "  --stealth           Enable stealth feature (enabled by default), anti-detection + tracker blocking"
    echo "  --no-stealth        Disable stealth feature"
    echo ""
    echo "General options:"
    echo "  clean               Clean V8 build cache (gn_out + build script output)"
    echo "                      Can be combined with build options: clean --release"
    echo "  -h, --help          Show help"
    echo ""
    echo "Examples:"
    echo "  $0                                        # release build for aarch64, default args"
    echo "  $0 --debug                                # debug build for aarch64"
    echo "  $0 --arch x86_64                          # build x86_64 native version"
    echo "  $0 --arch x86_64 --debug                  # debug build for x86_64"
    echo "  $0 --debug --examples                     # debug build for aarch64 + V8 examples"
    echo "  $0 --debug clean                          # clean debug build cache"
    echo "  $0 --release clean                        # clean release build cache"
    echo "  $0 --release --target-dir ./target2       # specify output directory, default (./target/aarch64)"
    echo "  $0 -j20 -vv                               # custom cargo args (passthrough)"
    echo "  $0 --skip-vendor --force                  # force re-download deps, skip vendor"
    echo "  $0 --arch aarch64 --release               # stealth enabled by default"
    echo "  $0 --arch aarch64 --release --no-stealth  # disable stealth feature"
    exit 0
}

# Collect extra args passed through to cargo build (non-predefined flags are passed through)
PASSTHROUGH_ARGS=()

# Download module parameters (all enabled by default)
BD_SKIP_CLANG=0
BD_SKIP_RUST=0
BD_SKIP_NINJA_GN=0
BD_SKIP_LIBCLANG=0
BD_SKIP_SYSROOT=0
BD_SKIP_CMAKE=0
BD_SKIP_VENDOR=0
BD_VENDOR_ONLY=0
BD_FORCE=0
BUILD_V8_EXAMPLES=0
DO_PACKAGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            BUILD_MODE="--release"
            BUILD_REQUESTED=1
            MODE_EXPLICIT=1
            shift
            ;;
        --debug)
            BUILD_MODE=""
            BUILD_REQUESTED=1
            MODE_EXPLICIT=1
            shift
            ;;
        --arch)
            TARGET_ARCH="$2"
            BUILD_REQUESTED=1
            ARCH_EXPLICIT=1
            shift 2
            ;;
        --arch=*)
            TARGET_ARCH="${1#*=}"
            BUILD_REQUESTED=1
            ARCH_EXPLICIT=1
            shift
            ;;
        --target-dir)
            TARGET_DIR="$2"
            BUILD_REQUESTED=1
            shift 2
            ;;
        --target-dir=*)
            TARGET_DIR="${1#*=}"
            BUILD_REQUESTED=1
            shift
            ;;
        --cargo-args)
            CARGO_EXTRA_ARGS="$2"
            BUILD_REQUESTED=1
            shift 2
            ;;
        --cargo-args=*)
            CARGO_EXTRA_ARGS="${1#*=}"
            BUILD_REQUESTED=1
            shift
            ;;
        # Download module parameters
        --skip-clang)      BD_SKIP_CLANG=1; BUILD_REQUESTED=1; shift ;;
        --skip-rust)       BD_SKIP_RUST=1; BUILD_REQUESTED=1; shift ;;
        --skip-ninja-gn)   BD_SKIP_NINJA_GN=1; BUILD_REQUESTED=1; shift ;;
        --skip-libclang)   BD_SKIP_LIBCLANG=1; BUILD_REQUESTED=1; shift ;;
        --skip-sysroot)  BD_SKIP_SYSROOT=1; BUILD_REQUESTED=1; shift ;;
        --skip-cmake)    BD_SKIP_CMAKE=1; BUILD_REQUESTED=1; shift ;;
        --skip-vendor)   BD_SKIP_VENDOR=1; BUILD_REQUESTED=1; shift ;;
        --vendor-only)   BD_VENDOR_ONLY=1; shift ;;
        --force)         BD_FORCE=1; BUILD_REQUESTED=1; shift ;;
        --examples)      BUILD_V8_EXAMPLES=1; shift ;;
        --package)       DO_PACKAGE=1; BUILD_REQUESTED=1; shift ;;
        --stealth)       STEALTH_FEATURE=1; BUILD_REQUESTED=1; shift ;;
        --no-stealth)    STEALTH_FEATURE=0; BUILD_REQUESTED=1; shift ;;
        clean|--clean)
            DO_CLEAN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            # Unknown flag: pass through to cargo build
            PASSTHROUGH_ARGS+=("$1")
            BUILD_REQUESTED=1
            shift
            ;;
        *)
            # Non-flag arguments also passed through
            PASSTHROUGH_ARGS+=("$1")
            BUILD_REQUESTED=1
            shift
            ;;
    esac
done

# If there are passthrough args, append to default CARGO_EXTRA_ARGS
if [ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]; then
    CARGO_EXTRA_ARGS="${CARGO_EXTRA_ARGS} ${PASSTHROUGH_ARGS[*]}"
fi

# ===================== Architecture Configuration =====================
# Validate architecture and set related variables
case "$TARGET_ARCH" in
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        TARGET_LINK="aarch64-unknown-linux-gnu"
        ;;
    x86_64|amd64|x64)
        TARGET_ARCH="x86_64"
        TARGET_LINK="x86_64-unknown-linux-gnu"
        ;;
    *)
        echo -e "${RED}Error: Unsupported target architecture: $TARGET_ARCH${NC}"
        echo "Supported architectures: aarch64, x86_64"
        exit 1
        ;;
esac

# If user didn't explicitly specify --target-dir, use architecture-specific default
if [[ "$TARGET_DIR" == "" ]]; then
    TARGET_DIR="./target/${TARGET_ARCH}"
fi

# ===================== V8 Cache Cleanup =====================
# Only clean V8-related cache (gn_out + build script output), doesn't affect other Rust crates
# Cleaning gn_out forces V8 build.rs to re-run gn gen (maybe_gen detects gn_out missing)
# Cleaning build/v8-* forces cargo to re-run build.rs
do_clean() {
    # Determine which profile to clean based on build mode
    # Explicitly specified --release → clean release
    # Explicitly specified --debug or no mode specified → clean debug
    local profile
    if [[ "$MODE_EXPLICIT" -eq 1 ]] && [[ "$BUILD_MODE" == "--release" ]]; then
        profile="release"
    else
        profile="debug"
    fi

    echo "=== Cleaning V8 build cache (${profile}) ==="
    echo "  TARGET_DIR: ${TARGET_DIR}"

    local cleaned=0
    # Define metadata files to clean
    local meta_files=(
        "args.gn"
        "build.ninja"
        "build.ninja.d"
        "build.ninja.stamp"
    )

    # Iterate all possible gn_out directories
    for gn_dir in \
        "${TARGET_DIR}/${profile}/gn_out" \
        "${TARGET_DIR}/${TARGET_LINK}/${profile}/gn_out"; do
        if [[ -d "$gn_dir" ]]; then
            for file in "${meta_files[@]}"; do
                local target="${gn_dir}/${file}"
                if [[ -e "$target" ]]; then
                    echo "  Removing: $target"
                    rm -f "$target"
                    cleaned=1
                fi
            done
        fi
    done

    # cargo build script output (ensure build.rs re-runs)
    for build_dir in \
        "${TARGET_DIR}/${profile}/build" \
        "${TARGET_DIR}/${TARGET_LINK}/${profile}/build"; do
        if [[ -d "$build_dir" ]]; then
            for v8_dir in "$build_dir"/v8-*; do
                if [[ -d "$v8_dir" ]]; then
                    echo "  Removing: $v8_dir"
                    rm -rf "$v8_dir"
                    cleaned=1
                fi
            done
        fi
    done

    if [[ "$cleaned" -eq 0 ]]; then
        echo "  (Nothing to clean, ${profile} V8 cache does not exist)"
    fi
    echo "=== V8 cache cleanup complete ==="
    echo ""
}

# If clean specified, clean and exit
if [[ "$DO_CLEAN" == "1" ]]; then
    do_clean
    echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
    exit 0
fi

echo "=== Build Configuration ==="
echo "  TARGET_ARCH:   $TARGET_ARCH"
echo "  TARGET_LINK:   $TARGET_LINK"
echo "  BUILD_MODE:    ${BUILD_MODE:-debug}"
echo "  TARGET_DIR:    $TARGET_DIR"
echo "  CARGO_ARGS:    $CARGO_EXTRA_ARGS"
echo "================"
echo ""

# ===================== Rust Toolchain =====================
# RUST_DIR set during download phase by download_rust_toolchain (glob matches any version)
# RUSTC/CARGO/PATH/LD_LIBRARY_PATH exported after download complete (see "Export Rust Environment" section)

unset RUSTUP_TOOLCHAIN
unset RUSTUP_HOME
export CARGO_HOME="$OBSCURA_DIR/.cargo-home"   # Independent cache within project
mkdir -p "$CARGO_HOME"

# ===================== Download Dependencies =====================
cd "$OBSCURA_DIR"

# Rust cross-compilation toolchain download (check first, hard dependency, exit on failure)
if [[ "$BD_SKIP_RUST" -eq 0 ]]; then
    download_rust_toolchain || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Error: Rust toolchain download failed, cannot continue build${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
else
    echo ">>> Skipping Rust toolchain download"
fi

# Configure Rust environment variables first
export RUSTC="$RUST_DIR/rustc/bin/rustc"
export CARGO="$RUST_DIR/cargo/bin/cargo"
export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"

# Check if V8 source exists
if [[ ! -d "$V8_SRC_DIR" ]]; then
    echo "=== V8 source not found: $V8_SRC_DIR ==="
    echo ">>> Running cargo vendor to download dependencies..."
    create_cargo_configs
    run_vendor || exit 1

    # Re-evaluate V8_SRC_DIR (precise match v8-X.Y.Z format)
    V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    # Check again if V8 has been downloaded
    if [[ ! -d "$V8_SRC_DIR" ]]; then
        echo "Error: V8 source still not found after cargo vendor"
        exit 1
    fi
    echo "=== V8 source ready: $V8_SRC_DIR ==="
    echo ""
fi

if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
    create_cargo_configs
    run_vendor || exit 1
else
    # clang download (optional, continue on failure)
    if [[ "$BD_SKIP_CLANG" -eq 0 ]]; then
        download_clang || echo -e "${YELLOW}Warning: clang download failed, will use system clang${NC}"
    else
        echo ">>> Skipping clang download"
    fi

    # ninja/gn download (V8 build tools, cached under _deps shared across profiles)
    if [[ "$BD_SKIP_NINJA_GN" -eq 0 ]]; then
        download_ninja_gn || echo -e "${YELLOW}Warning: ninja/gn download failed, V8 build will auto-download${NC}"
    else
        echo ">>> Skipping ninja/gn download"
    fi

    # Set GN/NINJA environment variables so V8 build.rs skips redundant downloads
    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        export GN="$NINJA_GN_DIR/gn/gn"
        export NINJA="$NINJA_GN_DIR/ninja/ninja"
        echo "GN=$GN"
        echo "NINJA=$NINJA"
    fi

    # libclang download (hard dependency, exit on failure)
    if [[ "$BD_SKIP_LIBCLANG" -eq 0 ]]; then
        download_libclang || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Error: libclang download failed, cannot continue build${NC}"
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}libclang is a required dependency for bindgen, please check:${NC}"
            echo -e "${RED}  1. Is network connection working?${NC}"
            echo -e "${RED}  2. Try manual download: ${LIBCLANG_URL}${NC}"
            echo -e "${RED}  3. Or install system libclang: sudo apt install libclang-21-dev${NC}"
            exit 1
        }
    else
        echo ">>> Skipping libclang download"
    fi

    # cargo vendor must run before sysroot:
    # sysroot needs to create symlinks in V8 source tree, vendor ensures V8 directory structure exists
    if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
        # If V8 source already exists in third_party, vendor is already done, skip redundant download
        # Only need to run vendor when V8 is missing (first vendor block also handles this)
        if [[ -d "$V8_SRC_DIR" ]]; then
            echo ">>> Skipping cargo vendor (V8 source exists: $V8_SRC_DIR)"
        else
            create_cargo_configs
            run_vendor || exit 1
        fi
    else
        echo ">>> Skipping cargo vendor"
    fi

    # sysroot download (hard dependency, exit on failure)
    if [[ "$BD_SKIP_SYSROOT" -eq 0 ]]; then
        download_sysroot || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Error: sysroot download failed, cannot continue build${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> Skipping sysroot download"
    fi
fi

# stealth feature controlled via --stealth/--no-stealth (enabled by default)
# Requires cmake (BoringSSL build dependency)
# cmake download (only needed for --features stealth, for compiling BoringSSL)
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 0 ]]; then
    download_cmake || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Error: cmake download failed, --features stealth requires cmake to build BoringSSL${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
elif [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 1 ]]; then
    echo ">>> Skipping cmake download (--skip-cmake), please ensure cmake is installed"
fi

# ===================== Export Rust Environment (after downloads, RUST_DIR guaranteed set) =====================
if [ -z "$RUST_DIR" ]; then
    echo -e "${RED}Error: Rust toolchain not found, please ensure download_rust_toolchain ran successfully${NC}"
    exit 1
fi

# ===================== Build Environment Variables =====================

# ===================== Set Compiler (before ccache detection) =====================
# Project uses custom clang, need to set CC/CXX first so check_ccache.sh can wrap correctly
CLANG_DIR="${DEPS_DIR}/clang"
export CLANG_BASE_PATH="$CLANG_DIR"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# ===================== Check and Configure ccache =====================
# ccache can significantly speed up V8 and C/C++ compilation (80-90% improvement after first build)
# check_ccache.sh detects set CC/CXX and wraps as "ccache $CC"
source "$OBSCURA_DIR/_scripts/check_ccache.sh"

export PATH="$CLANG_DIR/bin:$PATH"
# stealth mode needs cmake, add to PATH so btls-sys build script can find it
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ -x "$CMAKE_DIR/bin/cmake" ]]; then
    export PATH="$CMAKE_DIR/bin:$PATH"
    echo -e "${BLUE}cmake added to PATH: $CMAKE_DIR/bin/cmake${NC}"
fi
# stealth mode: btls-sys prefix-symbols uses system nm/objcopy to rename BoringSSL symbols,
# but system tools don't support aarch64 target files. Create symlinks in _deps/clang/bin/ pointing to LLVM versions.
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    for tool in nm objcopy; do
        [[ -e "${CLANG_DIR}/bin/${tool}" ]] || ln -sf "llvm-${tool}" "${CLANG_DIR}/bin/${tool}"
    done
    echo -e "${BLUE}nm/objcopy symlinks ready: ${CLANG_DIR}/bin/{nm,objcopy} → llvm-*${NC}"
fi
export LD_LIBRARY_PATH="$RUST_DIR/rustc/lib:$LD_LIBRARY_PATH"
echo "RUST_DIR=$RUST_DIR"

# ===================== Set Build Environment Based on Architecture =====================
if [[ "$TARGET_ARCH" == "aarch64" ]]; then
    # ---- aarch64 cross-compilation (x86_64 host → aarch64 target)----
    # sysroot from build_download.sh: ${SYSROOT_CACHE_DIR}/debian_bullseye_arm64-sysroot
    export SYSROOT_DIR
    # bindgen: target is aarch64
    export BINDGEN_TARGET="aarch64-linux-gnu"

    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CLANG_DIR}/bin/clang"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=${BINDGEN_TARGET} -C link-arg=--sysroot=${SYSROOT_DIR} -C link-arg=-fuse-ld=lld -C link-arg=-B${CLANG_DIR}/bin"

    export CC_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/clang"
    export CXX_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/clang++"
    export CFLAGS_aarch64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export CXXFLAGS_aarch64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export AR_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/llvm-ar"

    # ccache wrapper
    if [[ "$CCACHE_ENABLED" == "1" ]]; then
        echo -e "${BLUE}=== Enabling ccache acceleration (aarch64 cross-compilation) ===${NC}"
        export CC_aarch64_unknown_linux_gnu="ccache ${CC_aarch64_unknown_linux_gnu}"
        export CXX_aarch64_unknown_linux_gnu="ccache ${CXX_aarch64_unknown_linux_gnu}"
        echo -e "${BLUE}  CC_aarch64_unknown_linux_gnu=${CC_aarch64_unknown_linux_gnu}${NC}"
        echo -e "${BLUE}  CXX_aarch64_unknown_linux_gnu=${CXX_aarch64_unknown_linux_gnu}${NC}"
    fi

elif [[ "$TARGET_ARCH" == "x86_64" ]]; then
    # ---- x86_64 native compilation (host == target)----
    # x86_64 uses amd64 sysroot (for V8 GN build)
    export SYSROOT_DIR="${AMD64_SYSROOT_DIR}"
    # bindgen: target is x86_64
    export BINDGEN_TARGET="x86_64-linux-gnu"

    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${CLANG_DIR}/bin/clang"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=${BINDGEN_TARGET} -C link-arg=--sysroot=${SYSROOT_DIR} -C link-arg=-fuse-ld=lld -C link-arg=-B${CLANG_DIR}/bin"

    export CC_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/clang"
    export CXX_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/clang++"
    export CFLAGS_x86_64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export CXXFLAGS_x86_64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export AR_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/llvm-ar"

    # ccache wrapper
    if [[ "$CCACHE_ENABLED" == "1" ]]; then
        echo -e "${BLUE}=== Enabling ccache acceleration (x86_64 native compilation) ===${NC}"
        export CC_x86_64_unknown_linux_gnu="ccache ${CC_x86_64_unknown_linux_gnu}"
        export CXX_x86_64_unknown_linux_gnu="ccache ${CXX_x86_64_unknown_linux_gnu}"
        echo -e "${BLUE}  CC_x86_64_unknown_linux_gnu=${CC_x86_64_unknown_linux_gnu}${NC}"
        echo -e "${BLUE}  CXX_x86_64_unknown_linux_gnu=${CXX_x86_64_unknown_linux_gnu}${NC}"
    fi
fi

# stealth mode: cmake doesn't support multi-word compiler paths (e.g. "ccache /path/to/clang"),
# btls-sys compiles BoringSSL via cmake, needs to strip ccache prefix from CC/CXX.
# Also set CMAKE_*_COMPILER_LAUNCHER=ccache, let cmake use ccache via launcher mechanism.
# Also needs -fuse-ld=lld, otherwise cmake uses system ld by default (doesn't support aarch64 cross-linking).
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$CCACHE_ENABLED" == "1" ]]; then
    echo -e "${BLUE}=== stealth mode: fixing cmake compatibility (ccache + linker) ===${NC}"
    [[ "$CC" == ccache\ * ]] && export CC="${CC#ccache }"
    [[ "$CXX" == ccache\ * ]] && export CXX="${CXX#ccache }"
    [[ "$CC_aarch64_unknown_linux_gnu" == ccache\ * ]] && export CC_aarch64_unknown_linux_gnu="${CC_aarch64_unknown_linux_gnu#ccache }"
    [[ "$CXX_aarch64_unknown_linux_gnu" == ccache\ * ]] && export CXX_aarch64_unknown_linux_gnu="${CXX_aarch64_unknown_linux_gnu#ccache }"
    [[ "$CC_x86_64_unknown_linux_gnu" == ccache\ * ]] && export CC_x86_64_unknown_linux_gnu="${CC_x86_64_unknown_linux_gnu#ccache }"
    [[ "$CXX_x86_64_unknown_linux_gnu" == ccache\ * ]] && export CXX_x86_64_unknown_linux_gnu="${CXX_x86_64_unknown_linux_gnu#ccache }"
    # cmake compiler launcher: cmake internally uses ccache to wrap compiler, equivalent to CC="ccache clang"
    export CMAKE_C_COMPILER_LAUNCHER=ccache
    export CMAKE_CXX_COMPILER_LAUNCHER=ccache
    echo -e "${BLUE}  CC=${CC}  (CMAKE_C_COMPILER_LAUNCHER=ccache)${NC}"
    echo -e "${BLUE}  CXX=${CXX}  (CMAKE_CXX_COMPILER_LAUNCHER=ccache)${NC}"
fi
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    # btls-sys cmake build needs lld linker (system ld doesn't support aarch64 cross-linking)
    export CFLAGS_aarch64_unknown_linux_gnu="${CFLAGS_aarch64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CXXFLAGS_aarch64_unknown_linux_gnu="${CXXFLAGS_aarch64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CXXFLAGS_x86_64_unknown_linux_gnu="${CXXFLAGS_x86_64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
fi

# Note: Do NOT export PKG_CONFIG_SYSROOT_DIR / PKG_CONFIG_LIBDIR / PKG_CONFIG_PATH here.
# These variables leak into V8's gn gen, and V8's pkg-config.py uses -s to specify sysroot
# but doesn't override PKG_CONFIG_SYSROOT_DIR, causing pkg-config to prepend arm64 sysroot
# to amd64 sysroot path. Other crates (e.g. zstd-sys) typically fallback to source build
# during cross-compile, don't depend on these variables.

# Configure bindgen (V8 build.rs uses it to generate Rust bindings)
# -nostdinc++ disables default C++ standard library search, specify V8's libc++ path
export LIBCLANG_PATH="${CLANG_DIR}/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc++ -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -isystem ${V8_SRC_DIR}/third_party/libc++/src/include -isystem ${V8_SRC_DIR}/third_party/libc++abi/src/include -isystem ${V8_SRC_DIR}/buildtools/third_party/libc++ -isystem ${CLANG_DIR}/lib/clang/21/include -isystem ${SYSROOT_DIR}/usr/include --sysroot=${SYSROOT_DIR} --target=${BINDGEN_TARGET}"

# ===================== Build =====================
# Ensure cargo config files exist (create_cargo_configs not called when V8 source already exists)
if [[ ! -f "$CARGO_CONFIG_BUILD" ]]; then
    create_cargo_configs
fi
echo "=== cargo build (using local vendor) ==="
cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"

# Safety: clean up PKG_CONFIG variables possibly inherited from external environment
unset PKG_CONFIG_SYSROOT_DIR
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH

# Specify V8 compilation parameters
# Must NOT add target_cpu=\"arm64\"
export GN_ARGS=" v8_use_external_startup_data=false use_sysroot=true extra_cflags=[\"-DV8_TLS_USED_IN_LIBRARY\" ]"
if [[ "$BUILD_MODE" != "--release" ]]; then
  export RUST_LOG=trace
  #v8_enable_v8_checks=true # Causes error: expression evaluates to '40 == 32' / static_assert(sizeof(v8::EscapableHandleScope) == sizeof(size_t) * 4
  # Disable pointer compression, fix Map pointer resolution error on ARM64 (only needed for aarch64)
  if [[ "$TARGET_ARCH" == "aarch64" ]]; then
    export GN_ARGS=" v8_enable_backtrace=true v8_enable_fast_mksnapshot=false dcheck_always_on=true v8_enable_pointer_compression=false ${GN_ARGS}"
  else
    export GN_ARGS=" v8_enable_backtrace=true v8_enable_fast_mksnapshot=false dcheck_always_on=true ${GN_ARGS}"
  fi
else
  export RUST_LOG=info
  export GN_ARGS=" v8_enable_fast_mksnapshot=true ${GN_ARGS}"
fi
echo "GN_ARGS: ${GN_ARGS}"

# Assemble cargo features flag
FEATURES_FLAG=""
if [[ "$STEALTH_FEATURE" == "1" ]]; then
    FEATURES_FLAG="$FEATURES_FLAG --features stealth"
    echo -e "${GREEN}--features stealth enable${NC}"
fi

# Assemble final build command
BUILD_CMD="V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
echo -e "${BLUE}$BUILD_CMD > ${TARGET_DIR}/build.log 2>&1${NC}"
# Ensure target directory exists
mkdir -p "${TARGET_DIR}"
# Actual build command
V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} > ${TARGET_DIR}/build.log 2>&1
BUILD_EXIT_CODE=$?
if [[ $BUILD_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}=== cargo build failed, exit code: ${BUILD_EXIT_CODE} ===${NC}"
    echo -e "${RED}=== View log: tail -100 ${TARGET_DIR}/build.log ===${NC}"
    exit $BUILD_EXIT_CODE
fi

# ===================== Build V8 Example Programs (optional) =====================
# V8 Rust crate examples: hello_world, shell, process, cppgc, cppgc-object
# Build artifacts located at: ${TARGET_DIR}/${TARGET_LINK}/<profile>/examples/
if [[ "$BUILD_V8_EXAMPLES" == "1" ]]; then
    echo ""
    echo -e "${BLUE}=== Building V8 example programs ===${NC}"
    # Determine profile directory name
    PROFILE_DIR="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE_DIR="release"

    V8_EXAMPLES_CMD="V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
    echo -e "${BLUE}$V8_EXAMPLES_CMD${NC}"
    V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} 2>&1 | tee ${TARGET_DIR}/examples_build.log
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        echo -e "${GREEN}=== V8 example build complete ===${NC}"
        echo "Artifacts location:"
        EXAMPLE_DIR="${TARGET_DIR}/${TARGET_LINK}/${PROFILE_DIR}/examples"
        #ls -lh "$EXAMPLE_DIR" 2>/dev/null || echo "  (See ${EXAMPLE_DIR})"
        ls -lh "$EXAMPLE_DIR" 2>/dev/null  || find "$EXAMPLE_DIR" -maxdepth 1 -type f -executable -exec ls -lh {} + 2>/dev/null || echo "  (No executables found: ${EXAMPLE_DIR})"
    else
        echo -e "${YELLOW}Warning: V8 example build failed (does not affect main program)${NC}"
    fi
fi

# Clean up temporary config files
rm -f "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG_BUILD"

# ===================== Packaging (optional) =====================
if [[ "$DO_PACKAGE" == "1" ]]; then
    PROFILE="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE="release"

    # Extract version from Cargo.toml
    PKG_VERSION=$(grep '^version' "$OBSCURA_DIR/Cargo.toml" | head -1 | sed -n 's/[^"]*"\([^"]*\)".*/\1/p')
    PKG_NAME="obscura-${PKG_VERSION}-${TARGET_ARCH}-linux"
    PKG_DIR="${OBSCURA_DIR}/dist/${PKG_NAME}"
    PKG_BIN_DIR="${PKG_DIR}/bin"
    PKG_TARBALL="${OBSCURA_DIR}/dist/${PKG_NAME}.tar.gz"

    # Build output path
    BUILD_OUT="${TARGET_DIR}/${TARGET_LINK}/${PROFILE}"

    echo ""
    echo "=== Creating package: ${PKG_NAME} ==="

    # Check if build artifact exists
    if [[ ! -x "${BUILD_OUT}/obscura" ]]; then
        echo -e "${RED}Error: Build artifact not found: ${BUILD_OUT}/obscura${NC}"
        echo -e "${RED}Please build successfully before using --package${NC}"
        exit 1
    fi

    # Create package directory
    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_BIN_DIR"

    # Copy binaries
    cp "${BUILD_OUT}/obscura" "$PKG_BIN_DIR/"
    cp "${BUILD_OUT}/obscura-worker" "$PKG_BIN_DIR/"

    # Strip debug symbols (significantly reduces size: debug 300MB → ~20MB)
    # Use llvm-strip to support cross-compilation artifacts
    LLVM_STRIP="${CLANG_DIR}/bin/llvm-strip"
    if [[ -x "$LLVM_STRIP" ]]; then
        echo ">>> Stripping binaries (${LLVM_STRIP})..."
        "$LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura"
        "$LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura-worker"
    else
        echo -e "${YELLOW}Warning: llvm-strip not found, skipping strip (binaries will be larger)${NC}"
    fi

    # Copy documentation
    [[ -f "$OBSCURA_DIR/README.md" ]] && cp "$OBSCURA_DIR/README.md" "$PKG_DIR/"
    [[ -f "$OBSCURA_DIR/LICENSE" ]] && cp "$OBSCURA_DIR/LICENSE" "$PKG_DIR/"

    # Create tar.gz
    mkdir -p "${OBSCURA_DIR}/dist"
    tar czf "$PKG_TARBALL" -C "${OBSCURA_DIR}/dist" "$PKG_NAME"

    PKG_SIZE=$(du -sh "$PKG_TARBALL" | cut -f1)
    BIN_SIZE_OBS=$(du -sh "$PKG_BIN_DIR/obscura" | cut -f1)
    BIN_SIZE_WRK=$(du -sh "$PKG_BIN_DIR/obscura-worker" | cut -f1)

    echo -e "${GREEN}=== Package created ===${NC}"
    echo -e "  File:    ${BLUE}${PKG_TARBALL}${NC}"
    echo -e "  Size:    ${BLUE}${PKG_SIZE}${NC}"
    echo -e "  Arch:    ${BLUE}${TARGET_ARCH}${NC}"
    echo -e "  Version: ${BLUE}${PKG_VERSION}${NC}"
    echo -e "  Mode:    ${BLUE}${PROFILE}${NC}"
    echo ""
    echo "  Contents:"
    echo -e "    ${PKG_NAME}/"
    echo -e "    ├── bin/"
    echo -e "    │   ├── obscura         (${BIN_SIZE_OBS})"
    echo -e "    │   └── obscura-worker  (${BIN_SIZE_WRK})"
    echo -e "    ├── README.md"
    echo -e "    └── LICENSE"
    echo ""
    echo "  Deploy:"
    echo "    tar xzf $(basename "$PKG_TARBALL")"
    echo "    cd ${PKG_NAME}/bin"
    echo "    ./obscura serve --port 9222"

    # Clean up temporary package directory (keep only tar.gz)
    rm -rf "$PKG_DIR"
fi

echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
exit 0
