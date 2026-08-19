#!/bin/bash

echo "begin time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"

# ===================== Resolve Project Root =====================
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# ===================== Prevent Concurrent Builds =====================
BUILD_LOCK="${OBSCURA_DIR}/target/android-aarch64/.build.lock"
mkdir -p "$(dirname "$BUILD_LOCK")"
if [ -f "$BUILD_LOCK" ]; then
    LOCK_PID=$(cat "$BUILD_LOCK" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo -e "\033[0;31mError: Another build process is running (PID $LOCK_PID)\033[0m"
        echo -e "\033[0;31m      Please wait for it to finish, or manually kill $LOCK_PID\033[0m"
        exit 1
    fi
    rm -f "$BUILD_LOCK"
fi
echo $$ > "$BUILD_LOCK"
trap 'rm -f "$BUILD_LOCK"' EXIT

# ===================== Ensure build_android.sh symlink in project root =====================
if [[ ! -L "${OBSCURA_DIR}/build_android.sh" ]]; then
    ln -sf "_scripts/build_android.sh" "${OBSCURA_DIR}/build_android.sh"
    echo "Created symlink: ${OBSCURA_DIR}/build_android.sh -> _scripts/build_android.sh"
fi

# ===================== Import Android Download Module =====================
source "$OBSCURA_DIR/_scripts/build_download_android.sh"

# ===================== Build Argument Parsing =====================
BUILD_MODE="--release"
TARGET_ARCH="aarch64"
TARGET_DIR=""
TARGET_LINK=""
CARGO_EXTRA_ARGS="-j20 -v"
DO_CLEAN=0
BUILD_REQUESTED=0
MODE_EXPLICIT=0
ARCH_EXPLICIT=0
STEALTH_FEATURE=1   # stealth enabled by default

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Build options:"
    echo "  --release           Build release version (default)"
    echo "  --debug             Build debug version"
    echo "  --arch ARCH         Target architecture: aarch64 (default) or x86_64"
    echo "  --target-dir DIR    Specify build output directory (default: ./target/android-<arch>)"
    echo "  --cargo-args ARGS   Extra arguments passed to cargo build (default: \"-j20 -v\")"
    echo "                      e.g.: \"--features render\" to enable render feature"
    echo "                      e.g.: \"--no-default-features\" to disable all default features"
    echo "                      e.g.: \"--features render,stealth\" to enable multiple features"
    echo "                      e.g.: \"--no-default-features --features stealth\" to enable only stealth"
    echo ""
    echo "Download options (passed through to build_download_android.sh):"
    echo "  --skip-clang        Skip clang download"
    echo "  --skip-rust         Skip Rust cross-compilation toolchain download"
    echo "  --skip-ninja-gn     Skip ninja/gn download"
    echo "  --skip-libclang     Skip libclang download"
    echo "  --skip-cmake        Skip cmake download"
    echo "  --skip-vendor       Skip cargo vendor"
    echo "  --vendor-only       Only run cargo vendor"
    echo "  --force             Force re-download of existing files"
    echo "  --skip-android-ndk      Skip Android NDK download"
    echo "  --skip-android-repos    Skip catapult clone"
    echo "  --skip-android-stdlib   Skip Android Rust stdlib download"
    echo ""
    echo "Other options:"
    echo "  --examples          Also build V8 example programs"
    echo "  --package           Create tar.gz package after build"
    echo "  --stealth           Enable stealth feature"
    echo "  --no-stealth        Disable stealth feature (default)"
    echo ""
    echo "General options:"
    echo "  clean               Clean V8 build cache"
    echo "  -h, --help          Show help"
    echo ""
    echo "Examples:"
    echo "  $0                                        # release build for aarch64-android"
    echo "  $0 --debug                                # debug build for aarch64-android"
    echo "  $0 --arch x86_64                          # build for x86_64-android"
    echo "  $0 --debug --examples                     # debug + V8 examples"
    echo "  $0 --debug clean                          # clean debug build cache"
    echo "  $0 --debug --stealth                      # debug + stealth feature enabled"
    exit 0
}

PASSTHROUGH_ARGS=()

BD_SKIP_CLANG=0
BD_SKIP_RUST=0
BD_SKIP_NINJA_GN=0
BD_SKIP_LIBCLANG=0
BD_SKIP_SYSROOT=0
BD_SKIP_CMAKE=0
BD_SKIP_VENDOR=0
BD_VENDOR_ONLY=0
BD_FORCE=0
BD_SKIP_ANDROID_NDK=0
BD_SKIP_ANDROID_REPOS=0
BD_SKIP_ANDROID_STDLIB=0
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
        --examples)              BUILD_V8_EXAMPLES=1; shift ;;
        --package)               DO_PACKAGE=1; shift ;;
        --stealth)               STEALTH_FEATURE=1; shift ;;
        --no-stealth)            STEALTH_FEATURE=0; shift ;;
        clean|--clean)
            DO_CLEAN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

if [ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]; then
    CARGO_EXTRA_ARGS="${CARGO_EXTRA_ARGS} ${PASSTHROUGH_ARGS[*]}"
fi

# ===================== Architecture Configuration =====================
case "$TARGET_ARCH" in
    aarch64|arm64)
        TARGET_ARCH="aarch64"
        TARGET_LINK="aarch64-linux-android"
        V8_TARGET_CPU="arm64"
        NDK_CLANG_PREFIX="aarch64-linux-android${NDK_API_LEVEL}"
        BINDGEN_TARGET="aarch64-linux-android"
        COMPILER_RT_ARCH="aarch64"
        ;;
    x86_64|amd64|x64)
        TARGET_ARCH="x86_64"
        TARGET_LINK="x86_64-linux-android"
        V8_TARGET_CPU="x64"
        NDK_CLANG_PREFIX="x86_64-linux-android${NDK_API_LEVEL}"
        BINDGEN_TARGET="x86_64-linux-android"
        COMPILER_RT_ARCH="x86_64"
        ;;
    *)
        echo -e "${RED}Error: Unsupported target architecture: $TARGET_ARCH${NC}"
        echo "Supported architectures: aarch64, x86_64"
        exit 1
        ;;
esac

NDK_SYSROOT="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
NDK_CLANG="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/${NDK_CLANG_PREFIX}-clang"
NDK_CLANGPP="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/${NDK_CLANG_PREFIX}-clang++"
NDK_LLVM_AR="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
NDK_LLVM_STRIP="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

if [[ "$TARGET_DIR" == "" ]]; then
    TARGET_DIR="./target/android-${TARGET_ARCH}"
fi

# ===================== V8 Cache Cleanup =====================
do_clean() {
    local profile
    if [[ "$MODE_EXPLICIT" -eq 1 ]] && [[ "$BUILD_MODE" == "--release" ]]; then
        profile="release"
    else
        profile="debug"
    fi

    echo "=== Cleaning V8 build cache (${profile}) ==="
    echo "  TARGET_DIR: ${TARGET_DIR}"

    local cleaned=0
    local meta_files=("args.gn" "build.ninja" "build.ninja.d" "build.ninja.stamp")

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
echo "  NDK_API:       $NDK_API_LEVEL"
echo "  STEALTH:       $([[ "$STEALTH_FEATURE" -eq 1 ]] && echo 'ON' || echo 'OFF')"
echo "================"
echo ""

# ===================== Rust Toolchain =====================
unset RUSTUP_TOOLCHAIN
unset RUSTUP_HOME
export CARGO_HOME="$OBSCURA_DIR/.cargo-home"
mkdir -p "$CARGO_HOME"

# ===================== Download Dependencies =====================
cd "$OBSCURA_DIR"

# Rust cross-compilation toolchain download
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

export RUSTC="$RUST_DIR/rustc/bin/rustc"
export CARGO="$RUST_DIR/cargo/bin/cargo"
export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"

# Android stdlib
if [[ "$BD_SKIP_ANDROID_STDLIB" -eq 0 ]]; then
    download_android_stdlib "$TARGET_LINK" || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Error: Android Rust stdlib download failed, cannot continue build${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
else
    echo ">>> Skipping Android stdlib download"
fi

# Check if V8 source exists
if [[ ! -d "$V8_SRC_DIR" ]]; then
    echo "=== V8 source not found: $V8_SRC_DIR ==="
    echo ">>> Running cargo vendor to download dependencies..."
    create_cargo_configs
    run_vendor || exit 1
    V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"
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
    # clang download
    if [[ "$BD_SKIP_CLANG" -eq 0 ]]; then
        download_clang || echo -e "${YELLOW}Warning: clang download failed, will use system clang${NC}"
    else
        echo ">>> Skipping clang download"
    fi

    # ninja/gn download
    if [[ "$BD_SKIP_NINJA_GN" -eq 0 ]]; then
        download_ninja_gn || echo -e "${YELLOW}Warning: ninja/gn download failed, V8 build will auto-download${NC}"
    else
        echo ">>> Skipping ninja/gn download"
    fi

    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        export GN="$NINJA_GN_DIR/gn/gn"
        export NINJA="$NINJA_GN_DIR/ninja/ninja"
        echo "GN=$GN"
        echo "NINJA=$NINJA"
    fi

    # libclang download (skip if using AOSP clang and libclang.so already exists)
    NEED_DL_LIBCLANG=1
    if [[ -f "$CLANG_DIR/lib/libclang.so" ]] && [[ "$CLANG_DIR" == "$AOSP_CLANG_DIR" ]]; then
        echo -e "${BLUE}libclang.so ready: $CLANG_DIR/lib/libclang.so${NC}"
        NEED_DL_LIBCLANG=0
    fi
    if [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && [[ "$NEED_DL_LIBCLANG" -eq 1 ]]; then
        download_libclang || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Error: libclang download failed, cannot continue build${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> Skipping libclang download"
    fi

    # cargo vendor
    if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
        if [[ -d "$V8_SRC_DIR" ]]; then
            echo ">>> Skipping cargo vendor (V8 source exists: $V8_SRC_DIR)"
        else
            create_cargo_configs
            run_vendor || exit 1
        fi
    else
        echo ">>> Skipping cargo vendor"
    fi

    # Android NDK
    if [[ "$BD_SKIP_ANDROID_NDK" -eq 0 ]]; then
        download_android_ndk || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}Error: Android NDK download failed, cannot continue build${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> Skipping Android NDK download"
    fi

    # catapult (not needed for android_platform, standalone V8 doesn't reference it)
    if [[ "$BD_SKIP_ANDROID_REPOS" -eq 0 ]]; then
        download_catapult || echo -e "${YELLOW}Warning: catapult download failed${NC}"
    else
        echo ">>> Skipping catapult download"
    fi
fi

# Debian sysroot (host V8 build tools need amd64 sysroot, Android target alone is not enough)
if [[ "$BD_SKIP_SYSROOT" -eq 0 ]]; then
    download_sysroot || echo -e "${YELLOW}Warning: sysroot download failed, host V8 build may fail${NC}"
fi

# cmake (only needed for --features stealth)
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 0 ]]; then
    download_cmake || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}Error: cmake download failed, --features stealth requires cmake${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
elif [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 1 ]]; then
    echo ">>> Skipping cmake download (--skip-cmake), please ensure cmake is installed"
fi

# Create V8 tree symlinks
create_android_v8_symlinks

# Create Android pydeps stubs for vendored V8 (avoid GN gen errors)
_create_v8_pydeps_stubs() {
    local ANDROID_DIR="${V8_SRC_DIR}/build/android"
    mkdir -p "$ANDROID_DIR/pylib/results/presentation" \
             "$ANDROID_DIR/test_wrapper" 2>/dev/null
    for f in \
        "pylib/results/presentation/test_results_presentation.pydeps" \
        "devil_chromium.pydeps" \
        "apk_operations.pydeps" \
        "test_runner.pydeps" \
        "test_wrapper/logdog_wrapper.pydeps" \
        "resource_sizes.pydeps"; do
        [ -f "$ANDROID_DIR/$f" ] || touch "$ANDROID_DIR/$f"
    done
}
_create_v8_pydeps_stubs

# ===================== Export Rust Environment =====================
if [ -z "$RUST_DIR" ]; then
    echo -e "${RED}Error: Rust toolchain not found${NC}"
    exit 1
fi

# ===================== Build Environment Variables =====================

# Prefer AOSP prebuilt clang, fallback to _deps/clang only when unavailable
AOSP_ROOT="$(cd "$OBSCURA_DIR/../../../../../.." && pwd -P)"
AOSP_CLANG_DIR="${AOSP_ROOT}/prebuilts/clang/host/linux-x86/clang-r574158"
VEN_CLANG_DIR="${DEPS_DIR}/clang"

if [[ -x "${AOSP_CLANG_DIR}/bin/clang" ]]; then
    CLANG_DIR="$AOSP_CLANG_DIR"
    echo "=== [AOSP] clang toolchain ready: ${CLANG_DIR} ==="
    # AOSP clang comes with libclang.so + libLLVM.so, no need to download
    if [[ -f "${CLANG_DIR}/lib/libclang.so" ]] && [[ -f "${CLANG_DIR}/lib/libLLVM.so" ]]; then
        BD_SKIP_LIBCLANG=1
    fi
else
    CLANG_DIR="$VEN_CLANG_DIR"
    echo "=== [VEN] clang toolchain ready: ${CLANG_DIR} ==="
fi

export CLANG_BASE_PATH="$CLANG_DIR"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# ===================== ccache =====================
source "$OBSCURA_DIR/_scripts/check_ccache.sh"

export PATH="$DEPS_DIR/bin:$CLANG_DIR/bin:$PATH"
# Rust build script needs cc as linker, provide relative path symlink from _deps/bin/
mkdir -p "$DEPS_DIR/bin"
if [[ ! -e "$DEPS_DIR/bin/cc" ]]; then
    _create_relative_symlink "${CLANG_DIR}/bin/clang" "$DEPS_DIR/bin/cc"
fi
# V8 host build needs pkg-config, use bundled _scripts/pkg-config.sh (avoid host deps)
if [[ ! -e "$DEPS_DIR/bin/pkg-config" ]]; then
    _create_relative_symlink "$OBSCURA_DIR/_scripts/pkg-config.sh" "$DEPS_DIR/bin/pkg-config"
fi
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ -x "$CMAKE_DIR/bin/cmake" ]]; then
    export PATH="$CMAKE_DIR/bin:$PATH"
    echo -e "${BLUE}cmake added to PATH: $CMAKE_DIR/bin/cmake${NC}"
fi

# stealth mode: nm/objcopy symlinks
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    for tool in nm objcopy; do
        [[ -e "${CLANG_DIR}/bin/${tool}" ]] || ln -sf "llvm-${tool}" "${CLANG_DIR}/bin/${tool}"
    done
    echo -e "${BLUE}nm/objcopy symlinks ready: ${CLANG_DIR}/bin/{nm,objcopy} → llvm-*${NC}"
fi

# Fix broken symlinks in NDK bin directory (Python zipfile extraction turns symlinks into small text files)
_fix_ndk_symlinks() {
    local ndk_bin_dir="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin"
    [[ -d "$ndk_bin_dir" ]] || return 0
    local fixed=0
    cd "$ndk_bin_dir" || return 0
    for f in *; do
        [[ -L "$f" ]] && continue      # Already a symlink
        [[ -f "$f" ]] || continue      # Not a regular file
        local sz
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        (( sz >= 64 )) && continue     # Normal binary
        local target
        target=$(cat "$f" 2>/dev/null | tr -d '\0')
        if [[ -n "$target" ]] && [[ -e "$target" ]]; then
            rm -f "$f"
            ln -sf "$target" "$f"
            ((fixed++))
        fi
    done
    cd - > /dev/null
    if (( fixed > 0 )); then
        echo -e "${BLUE}>>> Fixed ${fixed} broken symlinks in NDK${NC}"
    fi
}
_fix_ndk_symlinks

export LD_LIBRARY_PATH="$RUST_DIR/rustc/lib:$LD_LIBRARY_PATH"
echo "RUST_DIR=$RUST_DIR"

# ===================== Android Cross-Compilation Environment =====================

# btls-sys (stealth feature) needs ANDROID_NDK_HOME environment variable
export ANDROID_NDK_HOME="$ANDROID_NDK_DIR"

# sysroot uses NDK unified headers sysroot
export SYSROOT_DIR="$NDK_SYSROOT"

# Target python_script_name suffix (e.g. aarch64_linux_android / x86_64_linux_android)
TARGET_SUFFIX="$(echo "${TARGET_LINK}" | tr '-' '_')"

# CARGO_TARGET_ prefixed variable name (uppercase, e.g. AARCH64_LINUX_ANDROID)
CARGO_TARGET_ENV="$(echo "${TARGET_LINK}" | tr '[:lower:]-' '[:upper:]_')"

# Helper function: dynamically export target-specific environment variables
_export_target_var() {
    eval "export $1=\"\$2\""
}

# Linker: use NDK wrapper aarch64-linux-android24-clang++ (internal symlinks fixed)
# It handles --target / sysroot / compiler-rt automatically
_export_target_var "CARGO_TARGET_${CARGO_TARGET_ENV}_LINKER" "$NDK_CLANGPP"
# __clear_cache needs compiler-rt builtins
# strtod_l/strtof_l in Android bionic are only static inline, no global symbol → link stub library
NDK_RT_LIB="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux"
# Stored per target architecture, each architecture independent (avoid git dirty / wrong arch)
STUB_DIR="${ANDROID_DEPS_DIR}/stubs/${TARGET_ARCH}"
STUB_LIB="${STUB_DIR}/libndk_stubs.a"
_generate_ndk_stubs() {
    # Reuse existing stub if it exists, code unchanged won't regenerate (no git dirty)
    if [ -f "$STUB_LIB" ]; then
        return 0
    fi
    mkdir -p "$STUB_DIR"
    cat > /tmp/ndk_stubs.c << 'CEOF'
#include <locale.h>
double strtod(const char *, char **);
float strtof(const char *, char **);
double strtod_l(const char *nptr, char **endptr, locale_t loc) { return strtod(nptr, endptr); }
float strtof_l(const char *nptr, char **endptr, locale_t loc) { return strtof(nptr, endptr); }
CEOF
    "$NDK_CLANG" --target="${BINDGEN_TARGET}${NDK_API_LEVEL}" -c /tmp/ndk_stubs.c -o /tmp/ndk_stubs.o && \
    "$NDK_LLVM_AR" rcs "$STUB_LIB" /tmp/ndk_stubs.o && \
    rm -f /tmp/ndk_stubs.c /tmp/ndk_stubs.o && \
    echo -e "${GREEN}>>> NDK stub library generated (${TARGET_ARCH}): $STUB_LIB${NC}"
}
_generate_ndk_stubs
_export_target_var "CARGO_TARGET_${CARGO_TARGET_ENV}_RUSTFLAGS" "-C link-arg=-L${STUB_DIR} -C link-arg=-lndk_stubs -C link-arg=${NDK_RT_LIB}/libclang_rt.builtins-${COMPILER_RT_ARCH}-android.a"

# C/C++ compiler: use Chromium clang + NDK sysroot
_export_target_var "CC_${TARGET_SUFFIX}" "${CLANG_DIR}/bin/clang"
_export_target_var "CXX_${TARGET_SUFFIX}" "${CLANG_DIR}/bin/clang++"

# Host-side native linker (AOSP compiler_wrapper doesn't support "cc")
_export_target_var "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER" "${CLANG_DIR}/bin/clang"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# CFLAGS / CXXFLAGS: specify target and NDK sysroot
ANDROID_CLANG_FLAGS="--target=${BINDGEN_TARGET}${NDK_API_LEVEL} --sysroot=${NDK_SYSROOT} -DANDROID -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__"
_export_target_var "CFLAGS_${TARGET_SUFFIX}" "$ANDROID_CLANG_FLAGS"
_export_target_var "CXXFLAGS_${TARGET_SUFFIX}" "$ANDROID_CLANG_FLAGS"

# AR
_export_target_var "AR_${TARGET_SUFFIX}" "$NDK_LLVM_AR"

# ccache wrapper
if [[ "$CCACHE_ENABLED" == "1" ]]; then
    echo -e "${BLUE}=== Enabling ccache acceleration (Android ${TARGET_ARCH} cross-compilation) ===${NC}"
    _export_target_var "CC_${TARGET_SUFFIX}" "ccache ${CLANG_DIR}/bin/clang"
    _export_target_var "CXX_${TARGET_SUFFIX}" "ccache ${CLANG_DIR}/bin/clang++"
fi

# stealth mode: cmake compatibility fix
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    echo -e "${BLUE}=== stealth mode: fixing cmake compatibility ===${NC}"

    # btls-sys build script reads CC_<target> via target_only_var("CC"),
    # and passes it as CMAKE_C_COMPILER to CMake.
    # This overrides NDK toolchain file's compiler selection, causing AOSP clang
    # (missing --target=aarch64-linux-android) to compile wrong architecture objects.
    # After unset, btls-sys won't set CMAKE_C_COMPILER,
    # cmake-rs won't set it when CMAKE_TOOLCHAIN_FILE is defined,
    # NDK toolchain file selects the correct compiler itself.
    unset "CC_${TARGET_SUFFIX}" "CXX_${TARGET_SUFFIX}"
    echo -e "${BLUE}  unset CC_${TARGET_SUFFIX} CXX_${TARGET_SUFFIX} (avoid overriding NDK toolchain compiler selection)${NC}"

    if [[ "$CCACHE_ENABLED" == "1" ]]; then
        [[ "$CC" == ccache\ * ]] && export CC="${CC#ccache }"
        [[ "$CXX" == ccache\ * ]] && export CXX="${CXX#ccache }"
        export CMAKE_C_COMPILER_LAUNCHER=ccache
        export CMAKE_CXX_COMPILER_LAUNCHER=ccache
    fi
fi

if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    _export_target_var "CFLAGS_${TARGET_SUFFIX}" "${ANDROID_CLANG_FLAGS} -fuse-ld=lld -B${NDK_CLANG%/*}"
    _export_target_var "CXXFLAGS_${TARGET_SUFFIX}" "${ANDROID_CLANG_FLAGS} -fuse-ld=lld -B${NDK_CLANG%/*}"
fi

# bindgen configuration
export LIBCLANG_PATH="${CLANG_DIR}/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc++ -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -DANDROID -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ -isystem ${V8_SRC_DIR}/third_party/libc++/src/include -isystem ${V8_SRC_DIR}/third_party/libc++abi/src/include -isystem ${V8_SRC_DIR}/buildtools/third_party/libc++ -isystem ${CLANG_DIR}/lib/clang/21/include -isystem ${NDK_SYSROOT}/usr/include --sysroot=${NDK_SYSROOT} --target=${BINDGEN_TARGET}${NDK_API_LEVEL}"

# ===================== Build =====================
if [[ ! -f "$CARGO_CONFIG_BUILD" ]]; then
    create_cargo_configs
fi
echo "=== cargo build (using local vendor) ==="
cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"

unset PKG_CONFIG_SYSROOT_DIR
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH

# GN_ARGS: base args + Android-specific args
# build.rs auto-adds target_os="android", target_cpu="arm64", use_sysroot=true based on target_os=android
# We additionally set android_ndk_root (since NDK is in non-default path)
export GN_ARGS=" v8_use_external_startup_data=false use_sysroot=true extra_cflags=[\"-DV8_TLS_USED_IN_LIBRARY\"] android_ndk_root=\"//third_party/android_ndk\""

if [[ "$BUILD_MODE" != "--release" ]]; then
    export RUST_LOG=trace
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
mkdir -p "${TARGET_DIR}"
V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} > ${TARGET_DIR}/build.log 2>&1
BUILD_EXIT_CODE=$?
if [[ $BUILD_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}=== cargo build failed, exit code: ${BUILD_EXIT_CODE} ===${NC}"
    echo -e "${RED}=== View log: tail -100 ${TARGET_DIR}/build.log ===${NC}"
    exit $BUILD_EXIT_CODE
fi

# ===================== Build V8 Example Programs =====================
if [[ "$BUILD_V8_EXAMPLES" == "1" ]]; then
    echo ""
    echo -e "${BLUE}=== Building V8 example programs ===${NC}"
    PROFILE_DIR="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE_DIR="release"

    V8_EXAMPLES_CMD="V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
    echo -e "${BLUE}$V8_EXAMPLES_CMD${NC}"
    V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} 2>&1 | tee ${TARGET_DIR}/examples_build.log
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        echo -e "${GREEN}=== V8 example build complete ===${NC}"
        EXAMPLE_DIR="${TARGET_DIR}/${TARGET_LINK}/${PROFILE_DIR}/examples"
        ls -lh "$EXAMPLE_DIR" 2>/dev/null || find "$EXAMPLE_DIR" -maxdepth 1 -type f -executable -exec ls -lh {} + 2>/dev/null || echo "  (No executables found: ${EXAMPLE_DIR})"
    else
        echo -e "${YELLOW}Warning: V8 example build failed (does not affect main program)${NC}"
    fi
fi

rm -f "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG_BUILD"

# ===================== Packaging =====================
if [[ "$DO_PACKAGE" == "1" ]]; then
    PROFILE="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE="release"

    PKG_VERSION=$(grep '^version' "$OBSCURA_DIR/Cargo.toml" | head -1 | sed -n 's/[^"]*"\([^"]*\)".*/\1/p')
    PKG_NAME="obscura-${PKG_VERSION}-${TARGET_ARCH}-android"
    PKG_DIR="${OBSCURA_DIR}/dist/${PKG_NAME}"
    PKG_BIN_DIR="${PKG_DIR}/bin"
    PKG_TARBALL="${OBSCURA_DIR}/dist/${PKG_NAME}.tar.gz"

    BUILD_OUT="${TARGET_DIR}/${TARGET_LINK}/${PROFILE}"

    echo ""
    echo "=== Creating package: ${PKG_NAME} ==="

    if [[ ! -x "${BUILD_OUT}/obscura" ]]; then
        echo -e "${RED}Error: Build artifact not found: ${BUILD_OUT}/obscura${NC}"
        exit 1
    fi

    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_BIN_DIR"

    cp "${BUILD_OUT}/obscura" "$PKG_BIN_DIR/"
    cp "${BUILD_OUT}/obscura-worker" "$PKG_BIN_DIR/"

    if [[ -x "$NDK_LLVM_STRIP" ]]; then
        echo ">>> Stripping binaries (${NDK_LLVM_STRIP})..."
        "$NDK_LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura"
        "$NDK_LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura-worker"
    elif [[ -x "${CLANG_DIR}/bin/llvm-strip" ]]; then
        echo ">>> Stripping binaries (${CLANG_DIR}/bin/llvm-strip)..."
        "${CLANG_DIR}/bin/llvm-strip" --strip-all "$PKG_BIN_DIR/obscura"
        "${CLANG_DIR}/bin/llvm-strip" --strip-all "$PKG_BIN_DIR/obscura-worker"
    fi

    [[ -f "$OBSCURA_DIR/README.md" ]] && cp "$OBSCURA_DIR/README.md" "$PKG_DIR/"
    [[ -f "$OBSCURA_DIR/LICENSE" ]] && cp "$OBSCURA_DIR/LICENSE" "$PKG_DIR/"

    mkdir -p "${OBSCURA_DIR}/dist"
    tar czf "$PKG_TARBALL" -C "${OBSCURA_DIR}/dist" "$PKG_NAME"

    PKG_SIZE=$(du -sh "$PKG_TARBALL" | cut -f1)
    BIN_SIZE_OBS=$(du -sh "$PKG_BIN_DIR/obscura" | cut -f1)
    BIN_SIZE_WRK=$(du -sh "$PKG_BIN_DIR/obscura-worker" | cut -f1)

    echo -e "${GREEN}=== Package created ===${NC}"
    echo -e "  File:    ${BLUE}${PKG_TARBALL}${NC}"
    echo -e "  Size:    ${BLUE}${PKG_SIZE}${NC}"
    echo -e "  Arch:    ${BLUE}${TARGET_ARCH}${NC}"
    echo -e "  Platform:${BLUE}android${NC}"
    echo -e "  Version: ${BLUE}${PKG_VERSION}${NC}"
    echo -e "  Mode:    ${BLUE}${PROFILE}${NC}"

    rm -rf "$PKG_DIR"
fi

echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
exit 0
