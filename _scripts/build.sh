#!/bin/bash

echo "begin time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"

# ===================== 解析项目根目录（realpath 跨平台处理软链接）=====================
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# ===================== 确保项目根目录有 build.sh 软链接 =====================
if [[ ! -L "${OBSCURA_DIR}/build.sh" ]]; then
    ln -sf "_scripts/build.sh" "${OBSCURA_DIR}/build.sh"
    echo "已创建软链接: ${OBSCURA_DIR}/build.sh -> _scripts/build.sh"
fi

# ===================== 引入下载模块 =====================
source "$OBSCURA_DIR/_scripts/build_download.sh"

# ===================== 编译参数解析 =====================
BUILD_MODE="--release"
TARGET_ARCH="aarch64"               # 目标架构：aarch64（默认）或 x86_64
TARGET_DIR=""                       # 根据架构自动设置
TARGET_LINK=""                      # Rust target triple，根据架构自动设置
#CARGO_EXTRA_ARGS="-j20 -vv"
CARGO_EXTRA_ARGS="-j20 -v"
DO_CLEAN=0
BUILD_REQUESTED=0
MODE_EXPLICIT=0   # 是否显式指定了 --debug 或 --release
ARCH_EXPLICIT=0   # 是否显式指定了 --arch
DOMONO_FEATURE=1  # 默认启用 domono feature（ARM64 上加载 bootstrap.js）
STEALTH_FEATURE=1 # 默认启用 stealth feature（反检测 + tracker 屏蔽）


usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "编译选项:"
    echo "  --release           编译 release 版本（默认）"
    echo "  --debug             编译 debug 版本"
    echo "  --arch ARCH         目标架构: aarch64（默认）或 x86_64"
    echo "  --target-dir DIR    指定编译输出目录（默认: ./target/<arch>）"
    echo "  --cargo-args ARGS   传递给 cargo build 的额外参数（默认: \"-j20 -vv\"）"
    echo "                      例如: \"-j8 -vv\" 或 \"-j32\""
    echo ""
    echo "下载选项（透传给 build_download.sh）:"
    echo "  --skip-clang        跳过 clang 下载"
    echo "  --skip-rust         跳过 Rust 交叉编译工具链下载"
    echo "  --skip-ninja-gn     跳过 ninja/gn 下载"
    echo "  --skip-libclang     跳过 libclang 下载"
    echo "  --skip-sysroot      跳过 sysroot 下载"
    echo "  --skip-cmake        跳过 cmake 下载（stealth 模式需要，默认开启）"
    echo "  --skip-vendor       跳过 cargo vendor"
    echo "  --vendor-only       只执行 cargo vendor"
    echo "  --force             强制重新下载已存在的文件"
    echo ""
    echo "其他选项:"
    echo "  --examples          同时编译 V8 示例程序（hello_world, shell, process 等）"
    echo "  --package           编译后制作 tar.gz 安装包（strip 压缩二进制 + README + LICENSE）"
    echo "  --domono            启用 domono feature（默认开启），ARM64 上显式加载 bootstrap.js"
    echo "  --no-domono         禁用 domono feature，恢复原始 snapshot 行为"
    echo "  --stealth           启用 stealth feature（默认开启），反检测 + tracker 屏蔽"
    echo "  --no-stealth        禁用 stealth feature"
    echo ""
    echo "通用选项:"
    echo "  clean               清理 V8 构建缓存（gn_out + build script 输出）"
    echo "                      可与编译选项组合使用: clean --release"
    echo "  -h, --help          显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                                        # release 编译 aarch64，默认参数"
    echo "  $0 --debug                                # debug 编译 aarch64"
    echo "  $0 --arch x86_64                          # 编译 x86_64 本机版本"
    echo "  $0 --arch x86_64 --debug                  # debug 编译 x86_64"
    echo "  $0 --debug --examples                     # debug 编译 aarch64 并编译 V8 示例"
    echo "  $0 --debug clean                          # 清理 debug 编译缓存"
    echo "  $0 --release clean                        # 清理 release 编译缓存"
    echo "  $0 --release --target-dir ./target2       # 指定输出目录，默认(./target/aarch64)"
    echo "  $0 -j20 -vv                               # 自定义 cargo 参数（透传）"
    echo "  $0 --skip-vendor --force                  # 强制重新下载依赖，不 vendor"
    echo "  $0 --arch aarch64 --release               # 默认启用 domono + stealth"
    echo "  $0 --arch aarch64 --release --domono      # 显式启用 domono（等同默认）"
    echo "  $0 --arch aarch64 --release --no-domono   # 禁用 domono，恢复原始 snapshot 行为"
    echo "  $0 --arch aarch64 --release --no-stealth  # 禁用 stealth feature"
    exit 0
}

# 收集透传给 cargo build 的额外参数（非预定义的标志都透传）
PASSTHROUGH_ARGS=()

# 下载模块参数（默认全部执行）
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
        # 下载模块参数
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
        --domono)        DOMONO_FEATURE=1; BUILD_REQUESTED=1; shift ;;
        --no-domono)     DOMONO_FEATURE=0; BUILD_REQUESTED=1; shift ;;
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
            # 未知标志：透传给 cargo build
            PASSTHROUGH_ARGS+=("$1")
            BUILD_REQUESTED=1
            shift
            ;;
        *)
            # 非标志参数也透传
            PASSTHROUGH_ARGS+=("$1")
            BUILD_REQUESTED=1
            shift
            ;;
    esac
done

# 如果有透传参数，追加到默认的 CARGO_EXTRA_ARGS
if [ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]; then
    CARGO_EXTRA_ARGS="${CARGO_EXTRA_ARGS} ${PASSTHROUGH_ARGS[*]}"
fi

# stealth feature 通过 --stealth/--no-stealth 控制（默认启用）
# 需要 cmake（BoringSSL 编译依赖）

# ===================== 架构配置 =====================
# 验证架构并设置相关变量
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
        echo -e "${RED}错误: 不支持的目标架构: $TARGET_ARCH${NC}"
        echo "支持的架构: aarch64, x86_64"
        exit 1
        ;;
esac

# 如果用户没有显式指定 --target-dir，使用架构相关的默认目录
if [[ "$TARGET_DIR" == "" ]]; then
    TARGET_DIR="./target/${TARGET_ARCH}"
fi

# ===================== V8 缓存清理 =====================
# 只清理 V8 相关缓存（gn_out + build script 输出），不影响其他 Rust crate
# 清理 gn_out 会强制 V8 build.rs 重新运行 gn gen（maybe_gen 检测 gn_out 不存在才执行）
# 清理 build/v8-* 会强制 cargo 重新运行 build.rs
do_clean() {
    # 根据构建模式决定清理哪个 profile
    # 显式指定了 --release → 清理 release
    # 显式指定了 --debug 或未指定模式 → 清理 debug
    local profile
    if [[ "$MODE_EXPLICIT" -eq 1 ]] && [[ "$BUILD_MODE" == "--release" ]]; then
        profile="release"
    else
        profile="debug"
    fi

    echo "=== 清理 V8 构建缓存（${profile}） ==="
    echo "  TARGET_DIR: ${TARGET_DIR}"

    local cleaned=0
    # 定义需要清理的元数据文件列表
    local meta_files=(
        "args.gn"
        "build.ninja"
        "build.ninja.d"
        "build.ninja.stamp"
    )

    # 遍历所有可能的 gn_out 目录
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

    # cargo build script 输出（确保 build.rs 重新运行）
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

# 如果指定了 clean，清理后直接退出
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
echo "  CARGO_ARGS:    $CARGO_EXTRA_ARGS"
echo "================"
echo ""

# ===================== Rust 工具链 =====================
# RUST_DIR 在下载阶段由 download_rust_toolchain 设置（glob 匹配任意版本）
# RUSTC/CARGO/PATH/LD_LIBRARY_PATH 在下载完成后统一导出（见"导出 Rust 环境"段）

unset RUSTUP_TOOLCHAIN
unset RUSTUP_HOME
export CARGO_HOME="$OBSCURA_DIR/.cargo-home"   # 项目内独立 cache
mkdir -p "$CARGO_HOME"

# ===================== 下载依赖 =====================
cd "$OBSCURA_DIR"

# Rust 交叉编译工具链下载（优先检查，强依赖，失败时退出）
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

# 优先配置rust环境变量
export RUSTC="$RUST_DIR/rustc/bin/rustc"
export CARGO="$RUST_DIR/cargo/bin/cargo"
export PATH="$RUST_DIR/rustc/bin:$RUST_DIR/cargo/bin:$RUST_DIR/clippy-preview/bin:$PATH"

# 检查 V8 源代码是否存在
if [[ ! -d "$V8_SRC_DIR" ]]; then
    echo "=== V8 源代码不存在: $V8_SRC_DIR ==="
    echo ">>> 运行 cargo vendor 下载依赖..."
    create_cargo_configs
    run_vendor || exit 1

    # 重新评估 V8_SRC_DIR（精确匹配 v8-X.Y.Z 格式）
    V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    # 再次检查 V8 是否已下载
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
    # clang 下载（可选，失败时继续）
    if [[ "$BD_SKIP_CLANG" -eq 0 ]]; then
        download_clang || echo -e "${YELLOW}警告: clang 下载失败，将使用系统 clang${NC}"
    else
        echo ">>> 跳过 clang 下载"
    fi

    # ninja/gn 下载（V8 构建工具，放在 _deps 下跨 profile 共享）
    if [[ "$BD_SKIP_NINJA_GN" -eq 0 ]]; then
        download_ninja_gn || echo -e "${YELLOW}警告: ninja/gn 下载失败，V8 构建时将自动下载${NC}"
    else
        echo ">>> 跳过 ninja/gn 下载"
    fi

    # 设置 GN/NINJA 环境变量，让 V8 build.rs 跳过重复下载
    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        export GN="$NINJA_GN_DIR/gn/gn"
        export NINJA="$NINJA_GN_DIR/ninja/ninja"
        echo "GN=$GN"
        echo "NINJA=$NINJA"
    fi

    # libclang 下载（强依赖，失败时退出）
    if [[ "$BD_SKIP_LIBCLANG" -eq 0 ]]; then
        download_libclang || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}错误: libclang 下载失败，编译无法继续${NC}"
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}libclang 是 bindgen 的必需依赖，请检查:${NC}"
            echo -e "${RED}  1. 网络连接是否正常${NC}"
            echo -e "${RED}  2. 尝试手动下载: ${LIBCLANG_URL}${NC}"
            echo -e "${RED}  3. 或安装系统 libclang: sudo apt install libclang-21-dev${NC}"
            exit 1
        }
    else
        echo ">>> 跳过 libclang 下载"
    fi

    # cargo vendor 必须在 sysroot 之前运行：
    # sysroot 需要在 V8 源码树内创建符号链接，vendor 确保 V8 目录结构存在
    if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
        create_cargo_configs
        run_vendor || exit 1
    else
        echo ">>> 跳过 cargo vendor"
    fi

    # sysroot 下载（强依赖，失败时退出）
    if [[ "$BD_SKIP_SYSROOT" -eq 0 ]]; then
        download_sysroot || {
            echo -e "${RED}========================================${NC}"
            echo -e "${RED}错误: sysroot 下载失败，编译无法继续${NC}"
            echo -e "${RED}========================================${NC}"
            exit 1
        }
    else
        echo ">>> 跳过 sysroot 下载"
    fi
fi

# cmake 下载（仅 --features stealth 需要，用于编译 BoringSSL）
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 0 ]]; then
    download_cmake || {
        echo -e "${RED}========================================${NC}"
        echo -e "${RED}错误: cmake 下载失败，--features stealth 需要 cmake 来编译 BoringSSL${NC}"
        echo -e "${RED}========================================${NC}"
        exit 1
    }
elif [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$BD_SKIP_CMAKE" -eq 1 ]]; then
    echo ">>> 跳过 cmake 下载（--skip-cmake），请确保系统已安装 cmake"
fi

# ===================== 导出 Rust 环境（下载完成后，RUST_DIR 保证已设置）=====================
if [ -z "$RUST_DIR" ]; then
    echo -e "${RED}错误: Rust 工具链未找到，请确保 download_rust_toolchain 已成功运行${NC}"
    exit 1
fi

# ===================== 编译环境变量 =====================

# ===================== 设置编译器（在 ccache 检测之前）=====================
# 项目使用自定义的 clang，需要先设置 CC/CXX，让 check_ccache.sh 能够正确包装
CLANG_DIR="${DEPS_DIR}/clang"
export CLANG_BASE_PATH="$CLANG_DIR"
export CC="${CLANG_DIR}/bin/clang"
export CXX="${CLANG_DIR}/bin/clang++"

# ===================== 检查并配置 ccache =====================
# ccache 可以显著加速 V8 和 C/C++ 编译（首次构建后，后续构建提升 80-90%）
# check_ccache.sh 会检测已设置的 CC/CXX，并包装为 "ccache $CC"
source "$OBSCURA_DIR/_scripts/check_ccache.sh"

export PATH="$CLANG_DIR/bin:$PATH"
# stealth 模式需要 cmake，加入 PATH 让 btls-sys 的 build script 能找到
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ -x "$CMAKE_DIR/bin/cmake" ]]; then
    export PATH="$CMAKE_DIR/bin:$PATH"
    echo -e "${BLUE}cmake 已加入 PATH: $CMAKE_DIR/bin/cmake${NC}"
fi
# stealth 模式: btls-sys 的 prefix-symbols 用系统 nm/objcopy 重命名 BoringSSL 符号，
# 但系统工具不支持 aarch64 目标文件。在 _deps/clang/bin/ 下建软链接指向 LLVM 版本。
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    for tool in nm objcopy; do
        [[ -e "${CLANG_DIR}/bin/${tool}" ]] || ln -sf "llvm-${tool}" "${CLANG_DIR}/bin/${tool}"
    done
    echo -e "${BLUE}nm/objcopy 软链接已就绪: ${CLANG_DIR}/bin/{nm,objcopy} → llvm-*${NC}"
fi
export LD_LIBRARY_PATH="$RUST_DIR/rustc/lib:$LD_LIBRARY_PATH"
echo "RUST_DIR=$RUST_DIR"

# ===================== 根据架构设置编译环境 =====================
if [[ "$TARGET_ARCH" == "aarch64" ]]; then
    # ---- aarch64 交叉编译（x86_64 host → aarch64 target）----
    # sysroot 来自 build_download.sh：${SYSROOT_CACHE_DIR}/debian_bullseye_arm64-sysroot
    export SYSROOT_DIR
    # bindgen：target 是 aarch64
    export BINDGEN_TARGET="aarch64-linux-gnu"

    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CLANG_DIR}/bin/clang"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=${BINDGEN_TARGET} -C link-arg=--sysroot=${SYSROOT_DIR} -C link-arg=-fuse-ld=lld -C link-arg=-B${CLANG_DIR}/bin"

    export CC_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/clang"
    export CXX_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/clang++"
    export CFLAGS_aarch64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export CXXFLAGS_aarch64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export AR_aarch64_unknown_linux_gnu="${CLANG_DIR}/bin/llvm-ar"

    # ccache 包装
    if [[ "$CCACHE_ENABLED" == "1" ]]; then
        echo -e "${BLUE}=== 启用 ccache 加速编译（aarch64 交叉编译） ===${NC}"
        export CC_aarch64_unknown_linux_gnu="ccache ${CC_aarch64_unknown_linux_gnu}"
        export CXX_aarch64_unknown_linux_gnu="ccache ${CXX_aarch64_unknown_linux_gnu}"
        echo -e "${BLUE}  CC_aarch64_unknown_linux_gnu=${CC_aarch64_unknown_linux_gnu}${NC}"
        echo -e "${BLUE}  CXX_aarch64_unknown_linux_gnu=${CXX_aarch64_unknown_linux_gnu}${NC}"
    fi

elif [[ "$TARGET_ARCH" == "x86_64" ]]; then
    # ---- x86_64 本机编译（host == target）----
    # x86_64 使用 amd64 sysroot（给 V8 的 GN 构建用）
    export SYSROOT_DIR="${AMD64_SYSROOT_DIR}"
    # bindgen：target 是 x86_64
    export BINDGEN_TARGET="x86_64-linux-gnu"

    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="${CLANG_DIR}/bin/clang"
    export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--target=${BINDGEN_TARGET} -C link-arg=--sysroot=${SYSROOT_DIR} -C link-arg=-fuse-ld=lld -C link-arg=-B${CLANG_DIR}/bin"

    export CC_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/clang"
    export CXX_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/clang++"
    export CFLAGS_x86_64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export CXXFLAGS_x86_64_unknown_linux_gnu="--target=${BINDGEN_TARGET} --sysroot=${SYSROOT_DIR}"
    export AR_x86_64_unknown_linux_gnu="${CLANG_DIR}/bin/llvm-ar"

    # ccache 包装
    if [[ "$CCACHE_ENABLED" == "1" ]]; then
        echo -e "${BLUE}=== 启用 ccache 加速编译（x86_64 本机编译） ===${NC}"
        export CC_x86_64_unknown_linux_gnu="ccache ${CC_x86_64_unknown_linux_gnu}"
        export CXX_x86_64_unknown_linux_gnu="ccache ${CXX_x86_64_unknown_linux_gnu}"
        echo -e "${BLUE}  CC_x86_64_unknown_linux_gnu=${CC_x86_64_unknown_linux_gnu}${NC}"
        echo -e "${BLUE}  CXX_x86_64_unknown_linux_gnu=${CXX_x86_64_unknown_linux_gnu}${NC}"
    fi
fi

# stealth 模式：cmake 不支持多词编译器路径（如 "ccache /path/to/clang"），
# btls-sys 通过 cmake 编译 BoringSSL，需要从 CC/CXX 中去掉 ccache 前缀。
# 同时设置 CMAKE_*_COMPILER_LAUNCHER=ccache，让 cmake 通过 launcher 机制使用 ccache。
# 同时需要 -fuse-ld=lld，否则 cmake 默认使用系统 ld（不支持 aarch64 交叉链接）。
if [[ "$STEALTH_FEATURE" -eq 1 ]] && [[ "$CCACHE_ENABLED" == "1" ]]; then
    echo -e "${BLUE}=== stealth 模式: 修复 cmake 兼容性（ccache + 链接器） ===${NC}"
    [[ "$CC" == ccache\ * ]] && export CC="${CC#ccache }"
    [[ "$CXX" == ccache\ * ]] && export CXX="${CXX#ccache }"
    [[ "$CC_aarch64_unknown_linux_gnu" == ccache\ * ]] && export CC_aarch64_unknown_linux_gnu="${CC_aarch64_unknown_linux_gnu#ccache }"
    [[ "$CXX_aarch64_unknown_linux_gnu" == ccache\ * ]] && export CXX_aarch64_unknown_linux_gnu="${CXX_aarch64_unknown_linux_gnu#ccache }"
    [[ "$CC_x86_64_unknown_linux_gnu" == ccache\ * ]] && export CC_x86_64_unknown_linux_gnu="${CC_x86_64_unknown_linux_gnu#ccache }"
    [[ "$CXX_x86_64_unknown_linux_gnu" == ccache\ * ]] && export CXX_x86_64_unknown_linux_gnu="${CXX_x86_64_unknown_linux_gnu#ccache }"
    # cmake compiler launcher：cmake 内部用 ccache 包装编译器，等价于 CC="ccache clang"
    export CMAKE_C_COMPILER_LAUNCHER=ccache
    export CMAKE_CXX_COMPILER_LAUNCHER=ccache
    echo -e "${BLUE}  CC=${CC}  (CMAKE_C_COMPILER_LAUNCHER=ccache)${NC}"
    echo -e "${BLUE}  CXX=${CXX}  (CMAKE_CXX_COMPILER_LAUNCHER=ccache)${NC}"
fi
if [[ "$STEALTH_FEATURE" -eq 1 ]]; then
    # btls-sys 的 cmake 构建需要 lld 链接器（系统 ld 不支持 aarch64 交叉链接）
    export CFLAGS_aarch64_unknown_linux_gnu="${CFLAGS_aarch64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CXXFLAGS_aarch64_unknown_linux_gnu="${CXXFLAGS_aarch64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CFLAGS_x86_64_unknown_linux_gnu="${CFLAGS_x86_64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
    export CXXFLAGS_x86_64_unknown_linux_gnu="${CXXFLAGS_x86_64_unknown_linux_gnu} -fuse-ld=lld -B${CLANG_DIR}/bin"
fi

# 注意：不要在此处 export PKG_CONFIG_SYSROOT_DIR / PKG_CONFIG_LIBDIR / PKG_CONFIG_PATH。
# 这些变量会泄漏到 V8 的 gn gen，而 V8 的 pkg-config.py 用 -s 指定 sysroot 但不覆盖
# PKG_CONFIG_SYSROOT_DIR，导致 pkg-config 把 arm64 sysroot 拼到 amd64 sysroot 路径上。
# 其他 crate（如 zstd-sys）在 cross-compile 时通常会 fallback 到源码编译，不依赖这些变量。

# 配置 bindgen（V8 build.rs 用它生成 Rust 绑定）
# -nostdinc++ 禁用默认 C++ 标准库搜索，指定 V8 的 libc++ 路径
export LIBCLANG_PATH="${CLANG_DIR}/lib"
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc++ -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS -isystem ${V8_SRC_DIR}/third_party/libc++/src/include -isystem ${V8_SRC_DIR}/third_party/libc++abi/src/include -isystem ${V8_SRC_DIR}/buildtools/third_party/libc++ -isystem ${CLANG_DIR}/lib/clang/21/include --sysroot=${SYSROOT_DIR} --target=${BINDGEN_TARGET}"

# ===================== 编译 =====================
echo "=== cargo build (使用本地 vendor) ==="
cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"

# 保险起见：清理可能从外部环境继承来的 PKG_CONFIG 变量
unset PKG_CONFIG_SYSROOT_DIR
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH

# 指定 v8 编译参数
# 不可以加 target_cpu=\"arm64\"
export GN_ARGS=" v8_use_external_startup_data=false use_sysroot=true extra_cflags=[\"-DV8_TLS_USED_IN_LIBRARY\" ]"
if [[ "$BUILD_MODE" != "--release" ]]; then
  export RUST_LOG=trace
  #v8_enable_v8_checks=true # 会导致错误 expression evaluates to '40 == 32' / static_assert(sizeof(v8::EscapableHandleScope) == sizeof(size_t) * 4
  # 禁用指针压缩，修复 ARM64 上的 Map 指针解析错误（仅 aarch64 需要）
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
# 确保目标目录存在
mkdir -p "${TARGET_DIR}"
# 实际编译命令
V8_FROM_SOURCE=1 PRINT_GN_ARGS=true cargo build ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} > ${TARGET_DIR}/build.log 2>&1

# ===================== 编译 V8 示例程序（可选）=====================
# V8 Rust crate 提供的示例：hello_world, shell, process, cppgc, cppgc-object
# 编译产物位于: ${TARGET_DIR}/${TARGET_LINK}/<profile>/examples/
if [[ "$BUILD_V8_EXAMPLES" == "1" ]]; then
    echo ""
    echo -e "${BLUE}=== 编译 V8 示例程序 ===${NC}"
    # 确定 profile 目录名
    PROFILE_DIR="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE_DIR="release"

    V8_EXAMPLES_CMD="V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR}"
    echo -e "${BLUE}$V8_EXAMPLES_CMD${NC}"
    V8_FROM_SOURCE=1 cargo build -p v8 --examples ${CARGO_EXTRA_ARGS} ${FEATURES_FLAG} ${BUILD_MODE} --target ${TARGET_LINK} --target-dir ${TARGET_DIR} 2>&1 | tee ${TARGET_DIR}/examples_build.log
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        echo -e "${GREEN}=== V8 示例编译完成 ===${NC}"
        echo "产物位置:"
        EXAMPLE_DIR="${TARGET_DIR}/${TARGET_LINK}/${PROFILE_DIR}/examples"
        #ls -lh "$EXAMPLE_DIR" 2>/dev/null || echo "  (查看 ${EXAMPLE_DIR})"
        ls -lh "$EXAMPLE_DIR" 2>/dev/null  || find "$EXAMPLE_DIR" -maxdepth 1 -type f -executable -exec ls -lh {} + 2>/dev/null || echo "  (未找到可执行文件: ${EXAMPLE_DIR})"
    else
        echo -e "${YELLOW}警告: V8 示例编译失败（不影响主程序）${NC}"
    fi
fi

# 清理临时配置文件
rm -f "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG_BUILD"

# ===================== 打包（可选）=====================
if [[ "$DO_PACKAGE" == "1" ]]; then
    PROFILE="debug"
    [[ "$BUILD_MODE" == "--release" ]] && PROFILE="release"

    # 从 Cargo.toml 提取版本号
    PKG_VERSION=$(grep '^version' "$OBSCURA_DIR/Cargo.toml" | head -1 | grep -oP '"\K[^"]+')
    PKG_NAME="obscura-${PKG_VERSION}-${TARGET_ARCH}-linux"
    PKG_DIR="${OBSCURA_DIR}/dist/${PKG_NAME}"
    PKG_BIN_DIR="${PKG_DIR}/bin"
    PKG_TARBALL="${OBSCURA_DIR}/dist/${PKG_NAME}.tar.gz"

    # 构建产物路径
    BUILD_OUT="${TARGET_DIR}/${TARGET_LINK}/${PROFILE}"

    echo ""
    echo "=== 制作安装包: ${PKG_NAME} ==="

    # 检查产物是否存在
    if [[ ! -x "${BUILD_OUT}/obscura" ]]; then
        echo -e "${RED}错误: 编译产物不存在: ${BUILD_OUT}/obscura${NC}"
        echo -e "${RED}请先编译成功后再使用 --package${NC}"
        exit 1
    fi

    # 创建打包目录
    rm -rf "$PKG_DIR"
    mkdir -p "$PKG_BIN_DIR"

    # 复制二进制文件
    cp "${BUILD_OUT}/obscura" "$PKG_BIN_DIR/"
    cp "${BUILD_OUT}/obscura-worker" "$PKG_BIN_DIR/"

    # strip 去除调试符号（大幅减小体积：debug 300MB → ~20MB）
    # 使用 llvm-strip 以支持交叉编译产物
    LLVM_STRIP="${CLANG_DIR}/bin/llvm-strip"
    if [[ -x "$LLVM_STRIP" ]]; then
        echo ">>> strip 二进制文件（${LLVM_STRIP}）..."
        "$LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura"
        "$LLVM_STRIP" --strip-all "$PKG_BIN_DIR/obscura-worker"
    else
        echo -e "${YELLOW}警告: llvm-strip 不存在，跳过 strip（二进制体积较大）${NC}"
    fi

    # 复制文档
    [[ -f "$OBSCURA_DIR/README.md" ]] && cp "$OBSCURA_DIR/README.md" "$PKG_DIR/"
    [[ -f "$OBSCURA_DIR/LICENSE" ]] && cp "$OBSCURA_DIR/LICENSE" "$PKG_DIR/"

    # 创建 tar.gz
    mkdir -p "${OBSCURA_DIR}/dist"
    tar czf "$PKG_TARBALL" -C "${OBSCURA_DIR}/dist" "$PKG_NAME"

    PKG_SIZE=$(du -sh "$PKG_TARBALL" | cut -f1)
    BIN_SIZE_OBS=$(du -sh "$PKG_BIN_DIR/obscura" | cut -f1)
    BIN_SIZE_WRK=$(du -sh "$PKG_BIN_DIR/obscura-worker" | cut -f1)

    echo -e "${GREEN}=== 安装包制作完成 ===${NC}"
    echo -e "  文件:   ${BLUE}${PKG_TARBALL}${NC}"
    echo -e "  大小:   ${BLUE}${PKG_SIZE}${NC}"
    echo -e "  架构:   ${BLUE}${TARGET_ARCH}${NC}"
    echo -e "  版本:   ${BLUE}${PKG_VERSION}${NC}"
    echo -e "  模式:   ${BLUE}${PROFILE}${NC}"
    echo ""
    echo "  内容:"
    echo -e "    ${PKG_NAME}/"
    echo -e "    ├── bin/"
    echo -e "    │   ├── obscura         (${BIN_SIZE_OBS})"
    echo -e "    │   └── obscura-worker  (${BIN_SIZE_WRK})"
    echo -e "    ├── README.md"
    echo -e "    └── LICENSE"
    echo ""
    echo "  部署:"
    echo "    tar xzf $(basename "$PKG_TARBALL")"
    echo "    cd ${PKG_NAME}/bin"
    echo "    ./obscura serve --port 9222"

    # 清理临时打包目录（只保留 tar.gz）
    rm -rf "$PKG_DIR"
fi

echo "end   time: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23)"
exit 0
