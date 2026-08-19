#!/bin/bash
# ============================================================
# build_aosp.sh - Build obscura using AOSP's native toolchain (Android target)
#
# Invoked via Android.mk within the AOSP tree, reusing AOSP's clang / sysroot
# directly. No additional NDK download needed (_deps/android/ can be skipped).
#
# AOSP invocation (parameters passed by Android.mk):
#   build_aosp.sh --mode debug --cc <clang> --cxx <clang++> --ar <ar> --sysroot <path> [--cargo-args "-j10"]
#
# Also supports standalone mode (reusing _deps/android/ndk-r26c):
#   build_aosp.sh --mode debug --standalone
# ============================================================

OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"
source "$OBSCURA_DIR/_scripts/build_download.sh"

MODE="debug"
STANDALONE=0
AOSP_RUST_HOME=""
AOSP_CC=""
AOSP_CXX=""
AOSP_AR=""
AOSP_SYSROOT=""
CARGO_EXTRA_ARGS="-j10"
NDK_API_LEVEL=24

usage() {
    echo "Usage: $0 --mode debug|release [--standalone] [--rust-home <path>] [--cc <path> --cxx <path> --ar <path> --sysroot <path>]"
    echo ""
    echo "  --standalone    Use bundled NDK (_deps/android/ndk-r26c)"
    echo "  --rust-home     Specify AOSP prebuilt Rust toolchain path"
    echo "  --cc / --cxx / --ar / --sysroot  Specify AOSP toolchain paths"
    echo "  --cargo-args    Arguments passed to cargo build (default: -j10)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       MODE="$2"; shift 2 ;;
        --standalone) STANDALONE=1; shift ;;
        --rust-home)  AOSP_RUST_HOME="$2"; shift 2 ;;
        --rust-home=*) AOSP_RUST_HOME="${1#*=}"; shift ;;
        --cc)         AOSP_CC="$2"; shift 2 ;;
        --cxx)        AOSP_CXX="$2"; shift 2 ;;
        --ar)         AOSP_AR="$2"; shift 2 ;;
        --sysroot)    AOSP_SYSROOT="$2"; shift 2 ;;
        --cargo-args) CARGO_EXTRA_ARGS="$2"; shift 2 ;;
        *)            echo "Unknown: $1"; usage ;;
    esac
done

# ===================== Rust Toolchain =====================
unset RUSTUP_TOOLCHAIN RUSTUP_HOME
export CARGO_HOME="$OBSCURA_DIR/.cargo-home"
mkdir -p "$CARGO_HOME"

if [ -n "$AOSP_RUST_HOME" ]; then
    if [ ! -x "$AOSP_RUST_HOME/bin/rustc" ]; then
        echo "Error: Invalid AOSP Rust toolchain: $AOSP_RUST_HOME/bin/rustc not found"
        exit 1
    fi
    RUST_DIR="$AOSP_RUST_HOME"
    export RUSTC="$RUST_DIR/bin/rustc"
    export CARGO="$RUST_DIR/bin/cargo"
    export PATH="$RUST_DIR/bin:$PATH"
    if [ ! -d "$RUST_DIR/lib/rustlib/aarch64-linux-android" ]; then
        echo "Error: aarch64-linux-android stdlib not installed"
        exit 1
    fi

# V8 build requires pkg-config and other system tools (AOSP build env has sanitized PATH)
export PATH="$PATH:/usr/bin"
else
    if [ -z "$RUST_DIR" ] || [ ! -x "$RUST_DIR/rustc/bin/rustc" ]; then
        echo "Error: Rust toolchain not ready, please run download_rust_toolchain first"
        exit 1
    fi
    export RUSTC="$RUST_DIR/rustc/bin/rustc"
    export CARGO="$RUST_DIR/cargo/bin/cargo"
    export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"
    if [ ! -d "${RUST_DIR}/rustc/lib/rustlib/aarch64-linux-android" ]; then
        echo "Error: aarch64-linux-android stdlib not installed"
        echo "Please run: ./build_download_android.sh"
        exit 1
    fi
fi

# ===================== Set Toolchain Paths =====================
if [ "$STANDALONE" -eq 1 ]; then
    # Standalone mode: use _deps/android/ndk-r26c
    NDK_DIR="${DEPS_DIR}/android/ndk-r26c"
    NDK_SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    LINKER="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${NDK_API_LEVEL}-clang++"
    CC="$CLANG_DIR/bin/clang"
    CXX="$CLANG_DIR/bin/clang++"
    AR="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar"
    SYSROOT="$NDK_SYSROOT"
    STUB_DIR="${DEPS_DIR}/android/stubs"
    RT_LIB="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/libclang_rt.builtins-aarch64-android.a"
else
    # AOSP mode: use provided toolchain
    if [ -z "$AOSP_CC" ] || [ -z "$AOSP_CXX" ]; then
        echo "Error: AOSP mode requires --cc / --cxx"
        exit 1
    fi
    LINKER="$AOSP_CXX"
    CC="$AOSP_CC"
    CXX="$AOSP_CXX"
    AR="${AOSP_AR:-$(dirname "$AOSP_CC")/llvm-ar}"
    SYSROOT="${AOSP_SYSROOT:-$(dirname "$AOSP_CC")/../sysroot}"
    if [ ! -d "$SYSROOT" ]; then
        NDK_DIR="${DEPS_DIR}/android/ndk-r26c"
        SYSROOT="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
        STUB_DIR="${DEPS_DIR}/android/stubs"
        RT_LIB="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/libclang_rt.builtins-aarch64-android.a"
    else
        STUB_DIR=""
        RT_LIB=""
    fi
fi

# ===================== cargo vendor =====================
create_cargo_configs
cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"

# ===================== Set cargo environment variables =====================
TARGET_LINK="aarch64-linux-android"
CARGO_ENV="$(echo "$TARGET_LINK" | tr '[:lower:]-' '[:upper:]_')"
TARGET_SUFFIX="$(echo "$TARGET_LINK" | tr '-' '_')"

_export_target_var() { eval "export $1=\"\$2\""; }

_export_target_var "CARGO_TARGET_${CARGO_ENV}_LINKER" "$LINKER"

# RUSTFLAGS
RUSTFLAGS=""
[ -n "$SYSROOT" ] && RUSTFLAGS="$RUSTFLAGS -C link-arg=--sysroot=$SYSROOT"
[ -n "$STUB_DIR" ] && RUSTFLAGS="$RUSTFLAGS -C link-arg=-L$STUB_DIR -C link-arg=-lndk_stubs"
[ -n "$RT_LIB" ] && RUSTFLAGS="$RUSTFLAGS -C link-arg=$RT_LIB"
_export_target_var "CARGO_TARGET_${CARGO_ENV}_RUSTFLAGS" "$RUSTFLAGS"

# C/C++ Compiler
export CC="$CC"
export CXX="$CXX"
_export_target_var "CC_${TARGET_SUFFIX}" "$CC"
_export_target_var "CXX_${TARGET_SUFFIX}" "$CXX"

# CFLAGS / CXXFLAGS
CFLAGS="--target=aarch64-linux-android24 -DANDROID -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__"
[ -n "$SYSROOT" ] && CFLAGS="$CFLAGS --sysroot=$SYSROOT"
_export_target_var "CFLAGS_${TARGET_SUFFIX}" "$CFLAGS"
_export_target_var "CXXFLAGS_${TARGET_SUFFIX}" "$CFLAGS"

# AR
_export_target_var "AR_${TARGET_SUFFIX}" "$AR"

# ===================== Build =====================
BUILD_MODE=""
[ "$MODE" = "release" ] && BUILD_MODE="--release"

# Specify clang as linker for host native build (AOSP compiler_wrapper does not support "cc")
HOST_TRIPLE="$("$RUSTC" -vV 2>/dev/null | grep '^host:' | awk '{print $2}')"
HOST_TRIPLE_ENV="$(echo "$HOST_TRIPLE" | tr '[:lower:]-' '[:upper:]_')"
_export_target_var "CARGO_TARGET_${HOST_TRIPLE_ENV}_LINKER" "$CC"

# V8 build requires GN and Ninja
if [ -d "${DEPS_DIR}/ninja_gn_binaries" ]; then
    export GN="${DEPS_DIR}/ninja_gn_binaries/gn/gn"
    export NINJA="${DEPS_DIR}/ninja_gn_binaries/ninja/ninja"
fi

CLANG_RESOURCE_DIR="$(ls -d "${CLANG_DIR}/lib/clang/"*/ 2>/dev/null | head -1 | sed 's:/*$::')"
if [ -z "$CLANG_RESOURCE_DIR" ]; then
    CLANG_RESOURCE_DIR="${CLANG_DIR}/lib/clang/21"
fi
export LIBCLANG_PATH="${CLANG_DIR}/lib"
export CLANG_BASE_PATH="${CLANG_DIR}"
export GN_ARGS="v8_use_external_startup_data=false use_sysroot=true android_ndk_root=\"//third_party/android_ndk\""
export BINDGEN_EXTRA_CLANG_ARGS="-DANDROID --target=aarch64-linux-android24 --sysroot=${SYSROOT} -resource-dir=${CLANG_RESOURCE_DIR}"

echo "=== AOSP build: mode=$MODE ==="
V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build $CARGO_EXTRA_ARGS --target "$TARGET_LINK" --target-dir "$OBSCURA_DIR/target/android-aarch64" $BUILD_MODE

rm -f "$CARGO_CONFIG_BUILD"
