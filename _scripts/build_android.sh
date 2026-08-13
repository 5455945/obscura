#!/bin/bash

echo "begin time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"

# ===================== 解析项目根目录 =====================
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# ===================== 防止并发编译 =====================
BUILD_LOCK="${OBSCURA_DIR}/target/android-aarch64/.build.lock"
mkdir -p "$(dirname "$BUILD_LOCK")"
if [ -f "$BUILD_LOCK" ]; then
    LOCK_PID=$(cat "$BUILD_LOCK" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo -e "\033[0;31m错误: 已有编译进程正在运行 (PID $LOCK_PID)\033[0m"
        echo -e "\033[0;31m      请等待其完成后再启动，或手动 kill $LOCK_PID\033[0m"
        exit 1
    fi
    rm -f "$BUILD_LOCK"
fi
echo $$ > "$BUILD_LOCK"
trap 'rm -f "$BUILD_LOCK"' EXIT

# ===================== 确保项目根目录有 build_android.sh 软链接 =====================
if [[ ! -L "${OBSCURA_DIR}/build_android.sh" ]]; then
    ln -sf "_scripts/build_android.sh" "${OBSCURA_DIR}/build_android.sh"
    echo "已创建软链接: ${OBSCURA_DIR}/build_android.sh -> _scripts/build_android.sh"
fi

# ===================== 引入 Android 下载模块 =====================
source "$OBSCURA_DIR/_scripts/build_download_android.sh"

# ===================== 编译参数解析 =====================
BUILD_MODE="--release"
TARGET_ARCH="aarch64"
TARGET_DIR=""
TARGET_LINK=""
CARGO_EXTRA_ARGS="-j20 -v"
DO_CLEAN=0
BUILD_REQUESTED=0
MODE_EXPLICIT=0
ARCH_EXPLICIT=0
DOMONO_FEATURE=1
STEALTH_FEATURE=0   # Android 默认关闭 stealth（BoringSSL 编译可能不兼容）

usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "编译选项:"
    echo "  --release           编译 release 版本（默认）"
    echo "  --debug             编译 debug 版本"
    echo "  --arch ARCH         目标架构: aarch64（默认）或 x86_64"
    echo "  --target-dir DIR    指定编译输出目录（默认: ./target/android-<arch>）"
    echo "  --cargo-args ARGS   传递给 cargo build 的额外参数（默认: \"-j20 -v\"）"
    echo ""
    echo "下载选项（透传给 build_download_android.sh）:"
    echo "  --skip-clang        跳过 clang 下载"
    echo "  --skip-rust         跳过 Rust 交叉编译工具链下载"
    echo "  --skip-ninja-gn     跳过 ninja/gn 下载"
    echo "  --skip-libclang     跳过 libclang 下载"
    echo "  --skip-cmake        跳过 cmake 下载"
    echo "  --skip-vendor       跳过 cargo vendor"
    echo "  --vendor-only       只执行 cargo vendor"
    echo "  --force             强制重新下载已存在的文件"
    echo "  --skip-android-ndk      跳过 Android NDK 下载"
    echo "  --skip-android-repos    跳过 catapult 克隆"
    echo "  --skip-android-stdlib   跳过 Android Rust stdlib 下载"
    echo ""
    echo "其他选项:"
    echo "  --examples          同时编译 V8 示例程序"
    echo "  --package           编译后制作 tar.gz 安装包"
    echo "  --domono            启用 domono feature（默认开启）"
    echo "  --no-domono         禁用 domono feature"
    echo "  --stealth           启用 stealth feature"
    echo "  --no-stealth        禁用 stealth feature（默认）"
    echo ""
    echo "通用选项:"
    echo "  clean               清理 V8 构建缓存"
    echo "  -h, --help          显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                                        # release 编译 aarch64-android"
    echo "  $0 --debug                                # debug 编译 aarch64-android"
    echo "  $0 --arch x86_64                          # 编译 x86_64-android"
    echo "  $0 --debug --examples                     # debug + V8 示例"
    echo "  $0 --debug clean                          # 清理 debug 编译缓存"
    echo "  $0 --debug --stealth                      # debug + stealth feature 启用"
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
        --domono)                DOMONO_FEATURE=1; shift ;;
        --no-domono)             DOMONO_FEATURE=0; shift ;;
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

# ===================== 架构配置 =====================
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
        echo -e "${RED}错误: 不支持的目标架构: $TARGET_ARCH${NC}"
        echo "支持的架构: aarch64, x86_64"
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

# ===================== V8 缓存清理 =====================
do_clean() {
    local profile
    if [[ "$MODE_EXPLICIT" -eq 1 ]] && [[ "$BUILD_MODE" == "--release" ]]; then
        profile="release"
    else
        profile="debug"
    fi

    echo "=== 清理 V8 构建缓存（${profile}） ==="
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
                    echo "  删除: $target"
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
                    echo "  删除: $v8_dir"
                    rm -rf "$v8_dir"
                    cleaned=1
                fi
            done
        fi
    done

    if [[ "$cleaned" -eq 0 ]]; then
        echo "  (无需清理，${profile} 的 V8 缓存不存在)"
    fi
    echo "=== V8 缓存清理完成 ==="
    echo ""
}

if [[ "$DO_CLEAN" == "1" ]]; then
    do_clean
    echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
    exit 0
fi

echo "=== 编译配置 ==="
echo "  TARGET_ARCH:   $TARGET_ARCH"
echo "  TARGET_LINK:   $TARGET_LINK"
echo "  BUILD_MODE:    ${BUILD_MODE:-debug}"
echo "  TARGET_DIR:    $TARGET_DIR"
echo "  NDK_API:       $NDK_API_LEVEL"
echo "  STEALTH:       $([[ "$STEALTH_FEATURE" -eq 1 ]] && echo 'ON' || echo 'OFF')"
echo "================"
echo ""

# ===================== Rust 工具链 =====================
unset RUSTUP_TOOLCHAIN
unset RUSTUP_HOME
export CARGO_HOME="$OBSCURA_DIR/.cargo-home"
mkdir -p "$CARGO_HOME"

# ===================== 下载依赖 =====================
cd "$OBSCURA_DIR"

# Rust 交叉编译工具链下载
if [[ "$BD_SKIP_RUST" -eq 0 ]]; then
    download_rust_toolchain || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}错误: Rust 工具链下载失败，编译无法继续${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
else
    echo ">>> 跳过 Rust 工具链下载"
fi

export RUSTC="$RUST_DIR/rustc/bin/rustc"
export CARGO="$RUST_DIR/cargo/bin/cargo"
export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"

# Android stdlib
if [[ "$BD_SKIP_ANDROID_STDLIB" -eq 0 ]]; then
    download_android_stdlib "$TARGET_LINK" || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}错误: Android Rust stdlib 下载失败，编译无法继续${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
else
    echo ">>> 跳过 Android stdlib 下载"
fi

# 检查 V8 源代码是否存在
if [[ ! -d "$V8_SRC_DIR" ]]; then
    echo "=== V8 源代码不存在: $V8_SRC_DIR ==="
    echo ">>> 运行 cargo vendor 下载依赖..."
    create_cargo_configs
    run_vendor || exit 1
    V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    V8_THIRD_PARTY_DIR="${V8_SRC_DIR}/third_party"
    if [[ ! -d "$V8_SRC_DIR" ]]; then
        echo "错误: cargo vendor 后仍未找到 V8 源代码"
        exit 1
    fi
    echo "=== V8 源代码已就绪: $V8_SRC_DIR ==="
    echo ""
fi

if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
    create_cargo_configs
    run_vendor || exit 1
else
    # clang 下载
    if [[ "$BD_SKIP_CLANG" -eq 0 ]]; then
        download_clang || echo -e "${YELLOW}警告: clang 下载失败，将使用系统 clang${NC}"
    else
        echo ">>> 跳过 clang 下载"
    fi

    # ninja/gn 下载
    if [[ "$BD_SKIP_NINJA_GN" -eq 0 ]]; then
        download_ninja_gn || echo -e "${YELLOW}警告: ninja/gn 下载失败，V8 构建时将自动下载${NC}"
    else
        echo ">>> 跳过 ninja/gn 下载"
    fi

    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        export GN="$NINJA_GN_DIR/gn/gn"
        export NINJA="$NINJA_GN_DIR/ninja/ninja"
        echo "GN=$GN"
        echo "NINJA=$NINJA"
    fi

    # libclang 下载（若使用 AOSP clang 且 libclang.so 已存在则跳过）
    NEED_DL_LIBCLANG=1
    if [[ -f "$CLANG_DIR/lib/libclang.so" ]] && [[ "$CLANG_DIR" == "$AOSP_CLANG_DIR" ]]; then
        echo -e "${BLUE}libclang.so 已就绪: $CLANG_DIR/lib/libclang.so${NC}"
        NEED_DL_LIBCLANG=0
    fi
    if [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && [[ "$NEED_DL_LIBCLANG" -eq 1 ]]; then
        download_libclang || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}错误: libclang 下载失败，编译无法继续${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> 跳过 libclang 下载"
    fi

    # cargo vendor
    if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
        if [[ -d "$V8_SRC_DIR" ]]; then
            echo ">>> 跳过 cargo vendor（V8 源已存在: $V8_SRC_DIR）"
        else
            create_cargo_configs
            run_vendor || exit 1
        fi
    else
        echo ">>> 跳过 cargo vendor"
    fi

    # Android NDK
    if [[ "$BD_SKIP_ANDROID_NDK" -eq 0 ]]; then
        download_android_ndk || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}错误: Android NDK 下载失败，编译无法继续${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> 跳过 Android NDK 下载"
    fi

    # catapult（android_platform 不需要，独立 V8 不引用它）
    if [[ "$BD_SKIP_ANDROID_REPOS" -eq 0 ]]; then
        download_catapult || echo -e "${YELLOW}警告: catapult 下载失败${NC}"
    else
        echo ">>> 跳过 catapult 下载"
    fi
fi

# Debian sysroot（host V8 构建工具需要 amd64 sysroot，仅 Android target 不够）
if [[ "$BD_SKIP_SYSROOT" -eq 0 ]]; then
    download_sysroot || echo -e "${YELLOW}警告: sysroot 下载失败，host V8 构建可能失败${NC}"
fi

# cmake（仅 --features stealth 需要）
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 0 ]]; then
    download_cmake || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}错误: cmake 下载失败，--features stealth 需要 cmake${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
elif [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 1 ]]; then
    echo ">>> 跳过 cmake 下载（--skip-cmake），请确保系统已安装 cmake"
fi

# 创建 V8 tree 内符号链接
create_android_v8_symlinks

# 创建 vendored V8 缺少的 Android pydeps 桩文件（避免 GN gen 报错）
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

# ===================== 导出 Rust 环境 =====================
if [ -z "$RUST_DIR" ]; then
    echo -e "${RED}错误: Rust 工具链未找到${NC}"
    exit 1
fi

# ===================== 编译环境变量 =====================

# 优先使用 AOSP 预编译 clang，仅当不可用时回退到 _deps/clang
AOSP_ROOT="$(cd "$OBSCURA_DIR/../../../../../.." && pwd -P)"
AOSP_CLANG_DIR="${AOSP_ROOT}/prebuilts/clang/host/linux-x86/clang-r574158"
VEN_CLANG_DIR="${DEPS_DIR}/clang"

if [[ -x "${AOSP_CLANG_DIR}/bin/clang" ]]; then
    CLANG_DIR="$AOSP_CLANG_DIR"
    echo "=== [AOSP] clang 工具链已就绪: ${CLANG_DIR} ==="
    # AOSP clang 自带 libclang.so + libLLVM.so，无需下载
    if [[ -f "${CLANG_DIR}/lib/libclang.so" ]] && [[ -f "${CLANG_DIR}/lib/libLLVM.so" ]]; then
        BD_SKIP_LIBCLANG=1
    fi
else
    CLANG_DIR="$VEN_CLANG_DIR"
    echo "=== [VEN] clang 工具链已就绪: ${CLANG_DIR} ==="
fi

export CLANG_BASE_PATH="$CLANG_DIR"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# ===================== ccache =====================
source "$OBSCURA_DIR/_scripts/check_ccache.sh"

export PATH="$DEPS_DIR/bin:$CLANG_DIR/bin:$PATH"
# Rust build script 需要 cc 作为 linker，从 _deps/bin/ 提供相对路径 symlink
mkdir -p "$DEPS_DIR/bin"
if [[ ! -e "$DEPS_DIR/bin/cc" ]]; then
    _create_relative_symlink "${CLANG_DIR}/bin/clang" "$DEPS_DIR/bin/cc"
fi
# V8 host 构建需要 pkg-config，使用自带的 _scripts/pkg-config.sh（避免 host 依赖）
if [[ ! -e "$DEPS_DIR/bin/pkg-config" ]]; then
    _create_relative_symlink "$OBSCURA_DIR/_scripts/pkg-config.sh" "$DEPS_DIR/bin/pkg-config"
fi
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ -x "$CMAKE_DIR/bin/cmake" ]]; then
    export PATH="$CMAKE_DIR/bin:$PATH"
    echo -e "${BLUE}cmake 已加入 PATH: $CMAKE_DIR/bin/cmake${NC}"
fi

# stealth 模式: nm/objcopy 软链接
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    for tool in nm objcopy; do
        [[ -e "${CLANG_DIR}/bin/${tool}" ]] || ln -sf "llvm-${tool}" "${CLANG_DIR}/bin/${tool}"
    done
    echo -e "${BLUE}nm/objcopy 软链接已就绪: ${CLANG_DIR}/bin/{nm,objcopy} → llvm-*${NC}"
fi

export LD_LIBRARY_PATH="$RUST_DIR/rustc/lib:$LD_LIBRARY_PATH"
echo "RUST_DIR=$RUST_DIR"

# ===================== Android 交叉编译环境设置 =====================

# sysroot 使用 NDK 的统一 headers sysroot
export SYSROOT_DIR="$NDK_SYSROOT"

# Target python_script_name 后缀（如 aarch64_linux_android / x86_64_linux_android）
TARGET_SUFFIX="$(echo "${TARGET_LINK}" | tr '-' '_')"

# CARGO_TARGET_ 前缀的变量名（大写，如 AARCH64_LINUX_ANDROID）
CARGO_TARGET_ENV="$(echo "${TARGET_LINK}" | tr '[:lower:]-' '[:upper:]_')"

# 辅助函数：动态导出 target 特定的环境变量
_export_target_var() {
    eval "export $1=\"\$2\""
}

# Linker：使用 NDK wrapper aarch64-linux-android24-clang++（已修复内部符号链接）
# 它自动处理 --target / sysroot / compiler-rt
_export_target_var "CARGO_TARGET_${CARGO_TARGET_ENV}_LINKER" "$NDK_CLANGPP"
# __clear_cache 需要 compiler-rt builtins
# strtod_l/strtof_l 在 Android bionic 中只有 static inline、无全局符号 → 链接 stub 库
NDK_RT_LIB="${ANDROID_NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux"
# 按目标架构分目录存放，架构切换时各自独立，互不覆盖（避免 git 飘红 / 用错架构）
STUB_DIR="${ANDROID_DEPS_DIR}/stubs/${TARGET_ARCH}"
STUB_LIB="${STUB_DIR}/libndk_stubs.a"
_generate_ndk_stubs() {
    # 对应架构的 stub 已存在则复用，代码不变就不会重新生成（不飘红）
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
    echo -e "${GREEN}>>> NDK stub 库已生成 (${TARGET_ARCH}): $STUB_LIB${NC}"
}
_generate_ndk_stubs
_export_target_var "CARGO_TARGET_${CARGO_TARGET_ENV}_RUSTFLAGS" "-C link-arg=-L${STUB_DIR} -C link-arg=-lndk_stubs -C link-arg=${NDK_RT_LIB}/libclang_rt.builtins-${COMPILER_RT_ARCH}-android.a"

# C/C++ 编译器：使用 Chromium clang + NDK sysroot
_export_target_var "CC_${TARGET_SUFFIX}" "${CLANG_DIR}/bin/clang"
_export_target_var "CXX_${TARGET_SUFFIX}" "${CLANG_DIR}/bin/clang++"

# Host 端 native 编译的 linker（AOSP compiler_wrapper 不支持 "cc"）
_export_target_var "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER" "${CLANG_DIR}/bin/clang"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# CFLAGS / CXXFLAGS：指定 target 和 NDK sysroot
ANDROID_CLANG_FLAGS="--target=${BINDGEN_TARGET}${NDK_API_LEVEL} --sysroot=${NDK_SYSROOT} -DANDROID -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__"
_export_target_var "CFLAGS_${TARGET_SUFFIX}" "$ANDROID_CLANG_FLAGS"
_export_target_var "CXXFLAGS_${TARGET_SUFFIX}" "$ANDROID_CLANG_FLAGS"

# AR
_export_target_var "AR_${TARGET_SUFFIX}" "$NDK_LLVM_AR"

# ccache 包装
if [[ "$CCACHE_ENABLED" == "1" ]]; then
    echo -e "${BLUE}=== 启用 ccache 加速编译（Android ${TARGET_ARCH} 交叉编译） ===${NC}"
    _export_target_var "CC_${TARGET_SUFFIX}" "ccache ${CLANG_DIR}/bin/clang"
    _export_target_var "CXX_${TARGET_SUFFIX}" "ccache ${CLANG_DIR}/bin/clang++"
fi

# stealth 模式：cmake 兼容性修复
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$CCACHE_ENABLED" == "1" ]]; then
    echo -e "${BLUE}=== stealth 模式: 修复 cmake 兼容性 ===${NC}"
    [[ "$CC" == ccache\ * ]] && export CC="${CC#ccache }"
    [[ "$CXX" == ccache\ * ]] && export CXX="${CXX#ccache }"
    export CMAKE_C_COMPILER_LAUNCHER=ccache
    export CMAKE_CXX_COMPILER_LAUNCHER=ccache
fi

if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    _export_target_var "CFLAGS_${TARGET_SUFFIX}" "${ANDROID_CLANG_FLAGS} -fuse-ld=lld -B${NDK_CLANG%/*}"
    _export_target_var "CXXFLAGS_${TARGET_SUFFIX}" "${ANDROID_CLANG_FLAGS} -fuse-ld=lld -B${NDK_CLANG%/*}"
fi

# bindgen 配置
export LIBCLANG_PATH="${CLANG_DIR}/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc++ -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -DANDROID -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ -isystem ${V8_SRC_DIR}/third_party/libc++/src/include -isystem ${V8_SRC_DIR}/third_party/libc++abi/src/include -isystem ${V8_SRC_DIR}/buildtools/third_party/libc++ -isystem ${CLANG_DIR}/lib/clang/21/include -isystem ${NDK_SYSROOT}/usr/include --sysroot=${NDK_SYSROOT} --target=${BINDGEN_TARGET}${NDK_API_LEVEL}"

# ===================== 编译 =====================
if [[ ! -f "$CARGO_CONFIG_BUILD" ]]; then
    create_cargo_configs
fi
echo "=== cargo build (使用本地 vendor) ==="
cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"

unset PKG_CONFIG_SYSROOT_DIR
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH

# GN_ARGS：基础参数 + Android 特定参数
# build.rs 会根据 target_os=android 自动添加 target_os="android", target_cpu="arm64", use_sysroot=true
# 我们需额外设置 android_ndk_root（因为 NDK 放在 non-default 路径）
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

# 组装 cargo features flag
FEATURES_FLAG=""
if [[ "$DOMONO_FEATURE" == "1" ]]; then
    FEATURES_FLAG="$FEATURES_FLAG --features obscura-js/domono"
    echo -e "${GREEN}--features obscura-js/domono enable${NC}"
fi
if [[ "$STEALTH_FEATURE" == "1" ]]; then
    FEATURES_FLAG="$FEATURES_FLAG --features stealth"
    echo -e "${GREEN}--features stealth enable${NC}"
fi

# 组装最终编译命令
BUILD_CMD="V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
echo -e "${BLUE}$BUILD_CMD > ${TARGET_DIR}/build.log 2>&1${NC}"
mkdir -p "${TARGET_DIR}"
V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} > ${TARGET_DIR}/build.log 2>&1
BUILD_EXIT_CODE=$?
if [[ $BUILD_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}=== cargo build 失败，退出码: ${BUILD_EXIT_CODE} ===${NC}"
    echo -e "${RED}=== 查看日志: tail -100 ${TARGET_DIR}/build.log ===${NC}"
    exit $BUILD_EXIT_CODE
fi

# ===================== 编译 V8 示例程序 =====================
if [[ "$BUILD_V8_EXAMPLES" == "1" ]]; then
    echo ""
    echo -e "${BLUE}=== 编译 V8 示例程序 ===${NC}"
    PROFILE_DIR="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE_DIR="release"

    V8_EXAMPLES_CMD="V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
    echo -e "${BLUE}$V8_EXAMPLES_CMD${NC}"
    V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} 2>&1 | tee ${TARGET_DIR}/examples_build.log
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        echo -e "${GREEN}=== V8 示例编译完成 ===${NC}"
        EXAMPLE_DIR="${TARGET_DIR}/${TARGET_LINK}/${PROFILE_DIR}/examples"
        ls -lh "$EXAMPLE_DIR" 2>/dev/null || find "$EXAMPLE_DIR" -maxdepth 1 -type f -executable -exec ls -lh {} + 2>/dev/null || echo "  (未找到可执行文件: ${EXAMPLE_DIR})"
    else
        echo -e "${YELLOW}警告: V8 示例编译失败（不影响主程序）${NC}"
    fi
fi

rm -f "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG_BUILD"

# ===================== 打包 =====================
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
    echo "=== 制作安装包: ${PKG_NAME} ==="

    if [[ ! -x "${BUILD_OUT}/obscura" ]]; then
        echo -e "${RED}错误: 编译产物不存在: ${BUILD_OUT}/obscura${NC}"
        exit 1
    fi

    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_BIN_DIR"

    cp "${BUILD_OUT}/obscura" "$PKG_BIN_DIR/"
    cp "${BUILD_OUT}/obscura-worker" "$PKG_BIN_DIR/"

    if [[ -x "$NDK_LLVM_STRIP" ]]; then
        echo ">>> strip 二进制文件（${NDK_LLVM_STRIP}）..."
        "$NDK_LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura"
        "$NDK_LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura-worker"
    elif [[ -x "${CLANG_DIR}/bin/llvm-strip" ]]; then
        echo ">>> strip 二进制文件（${CLANG_DIR}/bin/llvm-strip）..."
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

    echo -e "${GREEN}=== 安装包制作完成 ===${NC}"
    echo -e "  文件:   ${BLUE}${PKG_TARBALL}${NC}"
    echo -e "  大小:   ${BLUE}${PKG_SIZE}${NC}"
    echo -e "  架构:   ${BLUE}${TARGET_ARCH}${NC}"
    echo -e "  平台:   ${BLUE}android${NC}"
    echo -e "  版本:   ${BLUE}${PKG_VERSION}${NC}"
    echo -e "  模式:   ${BLUE}${PROFILE}${NC}"

    rm -rf "$PKG_DIR"
fi

echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
exit 0
