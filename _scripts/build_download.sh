#!/bin/bash
# ============================================================
# build_download.sh - 下载构建依赖（clang, libclang, cmake, sysroot, cargo vendor）
#
# 用法:
#   独立执行: ./build_download.sh [选项]
#   被引用:   source ./build_download.sh  （获取变量和函数，不执行下载）
#
# 选项:
#   --skip-clang       跳过 clang 下载
#   --skip-libclang    跳过 libclang 下载
#   --skip-cmake       跳过 cmake 下载（--features stealth 需要）
#   --skip-sysroot     跳过 sysroot 下载
#   --skip-vendor      跳过 cargo vendor
#   --vendor-only      只执行 cargo vendor（跳过其他所有下载）
#   --force            强制重新下载已存在的文件
#   -h, --help         显示帮助
# ============================================================

# 防止重复加载
[[ -n "$_BUILD_DOWNLOAD_LOADED" ]] && return 0 2>/dev/null
_BUILD_DOWNLOAD_LOADED=1

# ===================== 公共变量 =====================
# 解析项目根目录（realpath 跨平台处理软链接：Linux / macOS / MSYS2 / MinGW64）
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# 复用 V8 自带的 sysroot（既给 V8 的 GN 构建用，也给 Rust/cargo 的 clang 用）
# 精确匹配 v8-X.Y.Z 格式（如 v8-137.3.0），不匹配 v8-137.3.0.bak 或 v8-137.3.0_xx
V8_SRC_DIR=$(ls -td "${OBSCURA_DIR}"/third_party/v8-* 2>/dev/null | grep -E '/v8-[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

# 构建工具统一缓存在 _deps/ 下（clang、ninja/gn、sysroot 等），跨 profile 共享，避免重复下载
DEPS_DIR="${OBSCURA_DIR}/_deps"

# V8 下载的 clang
CLANG_DIR="${DEPS_DIR}/clang"

# sysroot 缓存在 _deps/sysroots/，V8 树内通过符号链接引用
# 这样 cargo vendor 清理 third_party/ 时不会丢失已下载的 sysroot
SYSROOT_CACHE_DIR="${DEPS_DIR}/sysroots"
SYSROOT_DIR="${SYSROOT_CACHE_DIR}/debian_bullseye_arm64-sysroot"
AMD64_SYSROOT_DIR="${SYSROOT_CACHE_DIR}/debian_bullseye_amd64-sysroot"

# ninja/gn 二进制文件（V8 构建需要）
NINJA_GN_DIR="${DEPS_DIR}/ninja_gn_binaries"

# Rust 交叉编译工具链（glob 匹配任意版本：rust-1.95.0、rust-1.96.0 等）
RUST_DIR=$(ls -td "${DEPS_DIR}"/rust-[0-9]*.[0-9]*.[0-9]*-x86_64-unknown-linux-gnu 2>/dev/null | head -1)

# cmake（--features stealth 需要：BoringSSL/btls-sys 编译依赖）
CMAKE_DIR="${DEPS_DIR}/cmake"
CMAKE_VERSION="3.31.6"

# libclang.so（bindgen 需要，Chromium 的 clang 包不包含）
# 版本号和 URL 在 download_libclang() 中动态从 V8 源码获取
LIBCLANG_DEB="/tmp/libclang1.deb"
LIBCLANG_DOWNLOAD_RETRIES=3

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Cargo 配置文件路径
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

# ===================== 下载函数 =====================

download_clang() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CLANG_DIR" ]]; then
        echo "=== [--force] 删除已有 clang 目录: $CLANG_DIR ==="
        rm -rf "$CLANG_DIR"
    fi

    if [ ! -f "$CLANG_DIR/bin/clang" ]; then
        echo "=== 预下载 V8 的 clang ==="
        echo -e "下载工具: ${BLUE}V8 tools/clang/scripts/update.py${NC}"
        echo -e "保存路径: ${BLUE}${CLANG_DIR}${NC}"
        ( cd "$V8_SRC_DIR" && python3 ./tools/clang/scripts/update.py --output-dir="$CLANG_DIR" --host-os=linux )
        if [ $? -ne 0 ]; then
            echo "错误: clang 下载失败"
            return 1
        fi
        echo "=== clang 下载完成: $CLANG_DIR ==="
        echo ""
    else
        echo -e "${BLUE}clang 已就绪: $CLANG_DIR${NC}"
    fi
}

# 检查 Rust 最新稳定版本，如果有比本地更新的版本，给出提示
# 该函数是 best-effort：网络失败时静默跳过，不影响构建流程
_check_rust_latest() {
    # 从本地目录名提取版本号，如 .../rust-1.95.0-x86_64-unknown-linux-gnu → 1.95.0
    local LOCAL_VERSION
    LOCAL_VERSION=$(basename "$RUST_DIR" | sed -n 's/.*rust-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    if [ -z "$LOCAL_VERSION" ]; then
        return 0
    fi

    # 下载 channel TOML（best-effort，超时 5 秒，失败静默）
    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML
    CHANNEL_TOML=$(mktemp /tmp/channel-rust-stable.XXXXXX.toml)
    if ! wget -q --timeout=5 -O "$CHANNEL_TOML" "$CHANNEL_URL" 2>/dev/null; then
        rm -f "$CHANNEL_TOML"
        return 0
    fi

    # 从 [pkg.rustc.target.x86_64-unknown-linux-gnu] 段的 url 提取最新版本号
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

    # 版本比较：使用 sort -V 按版本号排序，判断 LATEST_VERSION 是否严格大于 LOCAL_VERSION
    if [ "$LOCAL_VERSION" != "$LATEST_VERSION" ] && \
       [ "$(printf '%s\n%s' "$LOCAL_VERSION" "$LATEST_VERSION" | sort -V | tail -n1)" = "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}提示: 发现 Rust 最新稳定版本 ${LATEST_VERSION}（本地: ${LOCAL_VERSION}）${NC}"
        echo -e "${YELLOW}      如需升级，请删除本地工具链后重新运行: rm -rf ${RUST_DIR}${NC}"
    fi
}

download_rust_toolchain() {
    # 检查是否已存在任意版本的 Rust 工具链（glob 正则匹配）
    if [ -n "$RUST_DIR" ] && [ -x "$RUST_DIR/rustc/bin/rustc" ]; then
        if [[ "$BD_FORCE" == "1" ]]; then
            echo "=== [--force] 删除已有 Rust 工具链: $RUST_DIR ==="
            rm -rf "$RUST_DIR"
        else
            echo -e "${BLUE}Rust 工具链已就绪: $RUST_DIR ${NC}"
            # 联网检查最新稳定版本，如果有更新则给出提示（best-effort，网络失败静默跳过）
            _check_rust_latest
            return 0
        fi
    fi

    echo "=== 下载 Rust 稳定版交叉编译工具链 ==="

    # 1. 获取稳定版 channel TOML，解析最新版本的下载 URL
    local CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml"
    local CHANNEL_TOML="/tmp/channel-rust-stable.toml"

    echo -e "下载 channel 清单: ${BLUE}${CHANNEL_URL}${NC}"
    wget -q -O "$CHANNEL_TOML" "$CHANNEL_URL"
    if [ $? -ne 0 ]; then
        echo "错误: 下载 channel 清单失败"
        return 1
    fi

    # 2. 从 [pkg.rustc.target.*] 段提取 x86_64 和 aarch64 的 URL
    #    用 awk 限定在 pkg.rustc 段内，避免误取 rust-std/rust-docs 等其他包
    local HOST_URL TARGET_URL
    HOST_URL=$(awk '/^\[pkg\.rustc\.target\.x86_64-unknown-linux-gnu\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")
    TARGET_URL=$(awk '/^\[pkg\.rustc\.target\.aarch64-unknown-linux-gnu\]/{f=1} f&&/^url =/{gsub(/^url = "|"$|^$/, ""); print; exit}' "$CHANNEL_TOML")

    if [ -z "$HOST_URL" ] || [ -z "$TARGET_URL" ]; then
        echo "错误: 无法从 channel 清单提取 rustc URL"
        rm -f "$CHANNEL_TOML"
        return 1
    fi

    # 3. 从 URL 路径提取日期（如 2026-05-28）和版本号（如 1.96.0）
    local DOWNLOAD_DATE RUST_VERSION
    DOWNLOAD_DATE=$(echo "$HOST_URL" | sed -n 's/.*dist\/\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\).*/\1/p')
    RUST_VERSION=$(echo "$HOST_URL" | sed -n 's/.*rust\(c\)\{0,1\}-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\2/p')

    # 4. 构造 tarball URL 和文件名
    local HOST_TARBALL="rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
    local TARGET_TARBALL="rust-${RUST_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
    local HOST_TAR_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/${HOST_TARBALL}"
    local TARGET_TAR_URL="https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/${DOWNLOAD_DATE}/${TARGET_TARBALL}"

    echo -e "Rust 版本:  ${BLUE}${RUST_VERSION}${NC}"
    echo -e "发布日期:   ${BLUE}${DOWNLOAD_DATE}${NC}"
    echo -e "Host URL:   ${BLUE}${HOST_TAR_URL}${NC}"
    echo -e "Target URL: ${BLUE}${TARGET_TAR_URL}${NC}"

    rm -f "$CHANNEL_TOML"

    # 5. 下载两个 tarball 到 /tmp
    echo ">>> 下载 host 工具链 (x86_64)..."
    wget -c -P /tmp "$HOST_TAR_URL" || { echo "错误: 下载 host 工具链失败"; return 1; }
    echo ">>> 下载 target 标准库 (aarch64)..."
    wget -c -P /tmp "$TARGET_TAR_URL" || { echo "错误: 下载 target 标准库失败"; return 1; }

    # 6. 解压 x86_64 工具链到 _deps/
    mkdir -p "${DEPS_DIR}"
    echo ">>> 解压 x86_64 工具链到 ${DEPS_DIR}..."
    tar xzf "/tmp/${HOST_TARBALL}" -C "${DEPS_DIR}"
    local RUST_EXTRACTED="${DEPS_DIR}/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu"
    if [ ! -d "$RUST_EXTRACTED" ]; then
        echo "错误: 解压后目录不存在: $RUST_EXTRACTED"
        return 1
    fi

    # 7. 解压 aarch64 标准库到 /tmp（临时）
    echo ">>> 解压 aarch64 标准库..."
    tar xzf "/tmp/${TARGET_TARBALL}" -C /tmp/

    # 8. 组装交叉编译工具链
    #    将 x86_64 标准库顶层 lib/ 复制到工具链根目录
    cp -ar "${RUST_EXTRACTED}/rust-std-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu" "${RUST_EXTRACTED}/rustc/lib/rustlib/"

    #    将 aarch64 标准库添加到 rustlib/ 下（供交叉编译使用）
    cp -ar "/tmp/rust-${RUST_VERSION}-aarch64-unknown-linux-gnu/rust-std-aarch64-unknown-linux-gnu/lib/rustlib/aarch64-unknown-linux-gnu" \
           "${RUST_EXTRACTED}/rustc/lib/rustlib/"

    # 9. 清理 /tmp 中的 tarball 和解压目录
    #rm -f "/tmp/${HOST_TARBALL}" "/tmp/${TARGET_TARBALL}"
    #rm -rf "/tmp/rust-${RUST_VERSION}-aarch64-unknown-linux-gnu"

    # 10. 更新 RUST_DIR 全局变量
    RUST_DIR="$RUST_EXTRACTED"

    echo -e "${BLUE}=== Rust ${RUST_VERSION} 交叉编译工具链就绪: $RUST_DIR ===${NC}"
    echo ""
}

download_ninja_gn() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$NINJA_GN_DIR" ]]; then
        echo "=== [--force] 删除已有 ninja_gn_binaries 目录: $NINJA_GN_DIR ==="
        rm -rf "$NINJA_GN_DIR"
    fi

    # 检查 gn 和 ninja 是否都已存在
    if [ -f "$NINJA_GN_DIR/gn/gn" ] && [ -f "$NINJA_GN_DIR/ninja/ninja" ]; then
        echo -e "${BLUE}ninja/gn 已就绪: $NINJA_GN_DIR${NC}"
        return 0
    fi

    echo "=== 下载 ninja/gn 二进制文件 ==="
    echo -e "下载工具: ${BLUE}V8 tools/ninja_gn_binaries.py${NC}"
    echo -e "保存路径: ${BLUE}${NINJA_GN_DIR}${NC}"
    mkdir -p "$NINJA_GN_DIR"
    ( cd "$V8_SRC_DIR" && python3 ./tools/ninja_gn_binaries.py --dir="$NINJA_GN_DIR" )
    if [ $? -ne 0 ]; then
        echo "错误: ninja/gn 下载失败"
        return 1
    fi
    echo "=== ninja/gn 下载完成: $NINJA_GN_DIR ==="
    echo ""
}

download_cmake() {
    if [[ "$BD_FORCE" == "1" ]] && [[ -d "$CMAKE_DIR" ]]; then
        echo "=== [--force] 删除已有 cmake 目录: $CMAKE_DIR ==="
        rm -rf "$CMAKE_DIR"
    fi

    if [ -x "$CMAKE_DIR/bin/cmake" ]; then
        echo -e "${BLUE}cmake 已就绪: $CMAKE_DIR/bin/cmake ($("$CMAKE_DIR/bin/cmake" --version | head -1))${NC}"
        return 0
    fi

    echo "=== 下载 cmake ${CMAKE_VERSION}（--features stealth 需要） ==="

    # 确定平台后缀
    local PLATFORM_SUFFIX
    case "$(uname -s)" in
        Linux)  PLATFORM_SUFFIX="linux-x86_64" ;;
        Darwin) PLATFORM_SUFFIX="macos-universal" ;;
        *)
            echo -e "${RED}错误: 不支持的平台 $(uname -s)，无法自动下载 cmake${NC}"
            return 1
            ;;
    esac

    local TARBALL="cmake-${CMAKE_VERSION}-${PLATFORM_SUFFIX}.tar.gz"
    local GITHUB_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${TARBALL}"

    # 镜像列表：GitHub 直连 + ghfast.top 代理（国内加速）
    local URLS=(
        "$GITHUB_URL"
        "https://ghfast.top/${GITHUB_URL}"
    )

    mkdir -p "${DEPS_DIR}"
    local TMP_TARBALL="/tmp/${TARBALL}"

    local downloaded=0
    for url in "${URLS[@]}"; do
        echo -e ">>> 尝试下载: ${BLUE}${url}${NC}"
        wget -c --timeout=30 --tries=2 -P /tmp "$url" 2>&1 | tail -3
        if [[ $? -eq 0 ]] && [[ -f "$TMP_TARBALL" ]]; then
            # 验证文件大小（应该约 55MB）
            local FILE_SIZE
            FILE_SIZE=$(stat -c%s "$TMP_TARBALL" 2>/dev/null || stat -f%z "$TMP_TARBALL" 2>/dev/null)
            if [[ "$FILE_SIZE" -gt 10000000 ]]; then
                echo ">>> 下载成功 (大小: $((FILE_SIZE / 1024 / 1024))MB)"
                downloaded=1
                break
            else
                echo -e "${YELLOW}警告: 文件过小 ($FILE_SIZE bytes)，尝试下一个镜像${NC}"
                rm -f "$TMP_TARBALL"
            fi
        fi
    done

    if [[ $downloaded -eq 0 ]]; then
        echo -e "${RED}错误: cmake 下载失败（所有镜像均不可用）${NC}"
        echo -e "${RED}请手动下载安装: ${GITHUB_URL}${NC}"
        return 1
    fi

    # 解压到 _deps/cmake/（--strip-components=1 去掉顶层 cmake-X.Y.Z/ 目录）
    echo ">>> 解压到 ${CMAKE_DIR}..."
    mkdir -p "$CMAKE_DIR"
    tar xzf "$TMP_TARBALL" -C "$CMAKE_DIR" --strip-components=1
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: cmake 解压失败${NC}"
        rm -rf "$CMAKE_DIR"
        rm -f "$TMP_TARBALL"
        return 1
    fi

    rm -f "$TMP_TARBALL"

    echo -e "${GREEN}=== cmake ${CMAKE_VERSION} 就绪: $CMAKE_DIR/bin/cmake ===${NC}"
    echo ""
}

download_libclang() {
    # 从 V8 源码获取 clang 主版本号
    local V8_CLANG_UPDATE="${V8_SRC_DIR}/tools/clang/scripts/update.py"
    if [[ ! -f "$V8_CLANG_UPDATE" ]]; then
        echo -e "${RED}错误: 未找到 V8 clang 配置文件: $V8_CLANG_UPDATE${NC}"
        return 1
    fi

    local LIBCLANG_VERSION
    LIBCLANG_VERSION=$(grep "^RELEASE_VERSION" "$V8_CLANG_UPDATE" | sed -n "s/.*'\([0-9][0-9]*\).*/\1/p")
    if [[ -z "$LIBCLANG_VERSION" ]]; then
        echo -e "${RED}错误: 无法从 V8 提取 clang 版本号${NC}"
        return 1
    fi

    # 检查是否已存在该版本的 libclang
    if [[ "$BD_FORCE" == "1" ]]; then
        rm -f "$CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so"* 2>/dev/null
        rm -f "$LIBCLANG_DEB" 2>/dev/null
    fi

    if [[ -f "$CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]]; then
        echo -e "${BLUE}libclang.so 已就绪: $CLANG_DIR/lib/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}${NC}"
    else
        ## 从 apt.llvm.org 获取该版本的最新 libclang deb 包 URL
        ##local APT_INDEX_URL="https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"
        # 使用 TUNA 镜像（国内访问 apt.llvm.org 可能很慢）
        local APT_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"
        echo "=== 获取 libclang-${LIBCLANG_VERSION} 下载链接 ==="
        # https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-21/
        # https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-21/
        echo -e "索引页: ${BLUE}${APT_INDEX_URL}${NC}"

        local LIBCLANG_URL
        LIBCLANG_URL=$(curl -s "$APT_INDEX_URL" | sed -n "s/.*href=\"\(libclang1-${LIBCLANG_VERSION}[^\"]*amd64\.deb\)\".*/\1/p" | tail -1)
        if [[ -z "$LIBCLANG_URL" ]]; then
            echo -e "${RED}错误: 无法从 apt.llvm.org 获取 libclang-${LIBCLANG_VERSION} 包链接${NC}"
            return 1
        fi
        LIBCLANG_URL="${APT_INDEX_URL}${LIBCLANG_URL}"

        # https://apt.llvm.org/focal/pool/main/l/llvm-toolchain-21/libclang1-21_21.1.5~%2B%2B20251023083255%2B45afac62e373-1~exp1~20251023083404.50_amd64.deb
        # https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-21/libclang1-21_21.1.1~%2B%2B20250908083503%2Bfa462a66e418-1~exp1~20250908083623.25_amd64.deb
        echo -e "下载链接: ${BLUE}${LIBCLANG_URL}${NC}"
        echo -e "保存路径: ${BLUE}${LIBCLANG_DEB}${NC}"

        # 下载 deb 包（带重试机制和断点续传）
        for i in $(seq 1 $LIBCLANG_DOWNLOAD_RETRIES); do
            echo ">>> 下载 libclang1-${LIBCLANG_VERSION} 包（~7MB）... (尝试 $i/$LIBCLANG_DOWNLOAD_RETRIES)"
            # -C - 支持断点续传，如果文件已存在则从断点继续
            curl -L -C - --retry 3 --retry-delay 2 -o "$LIBCLANG_DEB" "$LIBCLANG_URL"
            if [[ $? -eq 0 ]]; then
                # 验证文件大小（应该约 7MB）
                local FILE_SIZE
                FILE_SIZE=$(stat -c%s "$LIBCLANG_DEB" 2>/dev/null || stat -f%z "$LIBCLANG_DEB" 2>/dev/null)
                if [[ "$FILE_SIZE" -gt 5000000 ]]; then
                    echo ">>> 下载成功 (大小: $((FILE_SIZE / 1024))KB)"
                    break
                else
                    echo -e "${YELLOW}警告: 文件过小 ($FILE_SIZE bytes)，可能下载不完整${NC}"
                    # 不删除文件，下次尝试时会续传
                fi
            fi
            if [[ $i -lt $LIBCLANG_DOWNLOAD_RETRIES ]]; then
                echo ">>> 重试中..."
                sleep 2
            fi
        done

        if [[ ! -f "$LIBCLANG_DEB" ]]; then
            echo -e "${RED}错误: libclang 下载失败（已重试 $LIBCLANG_DOWNLOAD_RETRIES 次）${NC}"
            echo -e "${RED}请检查网络连接或手动下载: ${LIBCLANG_URL}${NC}"
            return 1
        fi

        # 解压到临时目录，提取 libclang.so
        echo ">>> 提取 libclang.so 文件..."
        mkdir -p "$CLANG_DIR/lib"
        local LIBCLANG_EXTRACT_DIR
        LIBCLANG_EXTRACT_DIR=$(mktemp -d)
        dpkg-deb -x "$LIBCLANG_DEB" "$LIBCLANG_EXTRACT_DIR"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}错误: libclang 解压失败${NC}"
            echo -e "${RED}可能原因: 下载文件损坏，请尝试删除 $LIBCLANG_DEB 后重试${NC}"
            rm -rf "$LIBCLANG_EXTRACT_DIR"
            rm -f "$LIBCLANG_DEB"
            return 1
        fi

        # 复制 libclang.so 并创建符号链接
        if [[ ! -f "$LIBCLANG_EXTRACT_DIR/usr/lib/x86_64-linux-gnu/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]]; then
            echo -e "${RED}错误: 在 deb 包中未找到 libclang-${LIBCLANG_VERSION}.so${NC}"
            rm -rf "$LIBCLANG_EXTRACT_DIR"
            return 1
        fi

        cp "$LIBCLANG_EXTRACT_DIR/usr/lib/x86_64-linux-gnu/libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "$CLANG_DIR/lib/"
        rm -rf "$LIBCLANG_EXTRACT_DIR"
        rm -f "$LIBCLANG_DEB"
        echo -e "${GREEN}=== libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION} 提取完成 ===${NC}"
    fi

    # libLLVM.so（libclang 的运行时依赖，独立于 libclang deb 包）
    if [[ ! -f "$CLANG_DIR/lib/libLLVM.so.${LIBCLANG_VERSION}.1" ]]; then
        local LLVM_DEB="/tmp/libllvm${LIBCLANG_VERSION}.deb"
        local APT_INDEX_URL="https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/focal/pool/main/l/llvm-toolchain-${LIBCLANG_VERSION}/"

        echo "=== 获取 libllvm${LIBCLANG_VERSION} 下载链接 ==="
        local LLVM_URL
        LLVM_URL=$(curl -s "$APT_INDEX_URL" | sed -n "s/.*href=\"\(libllvm${LIBCLANG_VERSION}[^\"]*amd64\.deb\)\".*/\1/p" | tail -1)
        if [[ -z "$LLVM_URL" ]]; then
            echo -e "${RED}错误: 无法获取 libllvm${LIBCLANG_VERSION} 包链接${NC}"
            return 1
        fi
        LLVM_URL="${APT_INDEX_URL}${LLVM_URL}"
        echo -e "下载链接: ${BLUE}${LLVM_URL}${NC}"

        for i in $(seq 1 $LIBCLANG_DOWNLOAD_RETRIES); do
            echo ">>> 下载 libllvm${LIBCLANG_VERSION} 包... (尝试 $i/$LIBCLANG_DOWNLOAD_RETRIES)"
            curl -L -C - --retry 3 --retry-delay 2 -o "$LLVM_DEB" "$LLVM_URL"
            if [[ $? -eq 0 ]] && [[ -f "$LLVM_DEB" ]]; then
                break
            fi
            [[ $i -lt $LIBCLANG_DOWNLOAD_RETRIES ]] && sleep 2
        done

        if [[ ! -f "$LLVM_DEB" ]]; then
            echo -e "${RED}错误: libllvm${LIBCLANG_VERSION} 下载失败${NC}"
            return 1
        fi

        echo ">>> 提取 libLLVM.so..."
        local LLVM_EXTRACT_DIR
        LLVM_EXTRACT_DIR=$(mktemp -d)
        dpkg-deb -x "$LLVM_DEB" "$LLVM_EXTRACT_DIR"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}错误: libllvm 解压失败${NC}"
            rm -rf "$LLVM_EXTRACT_DIR"
            return 1
        fi

        local LLVM_LIB
        LLVM_LIB=$(find "$LLVM_EXTRACT_DIR" -name "libLLVM.so.${LIBCLANG_VERSION}.1" -print -quit)
        if [[ -z "$LLVM_LIB" ]]; then
            echo -e "${RED}错误: 在 deb 包中未找到 libLLVM.so.${LIBCLANG_VERSION}.1${NC}"
            rm -rf "$LLVM_EXTRACT_DIR"
            return 1
        fi

        cp "$LLVM_LIB" "$CLANG_DIR/lib/"
        rm -rf "$LLVM_EXTRACT_DIR"
        rm -f "$LLVM_DEB"
        echo -e "${GREEN}=== libLLVM.so.${LIBCLANG_VERSION}.1 提取完成 ===${NC}"
    else
        echo -e "${BLUE}libLLVM.so 已就绪: $CLANG_DIR/lib/libLLVM.so.${LIBCLANG_VERSION}.1${NC}"
    fi

    # 确保符号链接存在
    pushd "$CLANG_DIR/lib" > /dev/null
    [[ -f "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]] && [[ ! -L "libclang.so.${LIBCLANG_VERSION}" ]] && ln -sf "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "libclang.so.${LIBCLANG_VERSION}"
    [[ -f "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" ]] && [[ ! -L "libclang.so" ]] && ln -sf "libclang-${LIBCLANG_VERSION}.so.${LIBCLANG_VERSION}" "libclang.so"
    popd > /dev/null

    ls -lh "$CLANG_DIR/lib/libclang"*
}

# 在 V8 树内的指定路径创建指向缓存的符号链接
# 如果路径已是正确的符号链接则跳过；如果是旧实体目录则先迁移到缓存
# install-sysroot.py 不支持自定义输出目录，因此通过符号链接让 V8 GN 构建
# 能找到 _deps/sysroots/ 下的实际数据
link_sysroot() {
    local v8_path="$1"    # V8 树内的期望路径
    local cache_path="$2" # _deps/sysroots/ 下的缓存路径

    if [ -L "$v8_path" ]; then
        local current_target
        current_target=$(readlink "$v8_path")
        if [ "$current_target" = "$cache_path" ]; then
            return 0  # 符号链接已正确指向缓存
        fi
        # 符号链接指向其他位置，删除重建
        rm -f "$v8_path"
    fi

    # 如果是旧版安装的实体目录，迁移到缓存（避免重复下载）
    if [ -d "$v8_path" ] && [ ! -d "$cache_path" ]; then
        echo ">>> 迁移已有 sysroot 到缓存: $cache_path"
        mv "$v8_path" "$cache_path"
    elif [ -d "$v8_path" ]; then
        # 缓存已存在，删除旧实体目录
        rm -rf "$v8_path"
    fi

    _create_relative_symlink "$cache_path" "$v8_path"
}

# 确保单个 sysroot 已缓存且符号链接已建立
# 参数: $1=架构(arm64/amd64) $2=V8 树内路径 $3=缓存路径
#
# install-sysroot.py 内部使用 shutil.rmtree() 清理旧目录——
# 如果 V8 树内是符号链接，rmtree 会跟随链接删除缓存里的实际数据！
# 因此必须先移除符号链接，让 install-sysroot.py 直接操作缓存目录，最后再建链接。
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

    # 快速路径：缓存完整 + 符号链接正确 → 跳过
    if [ -f "$cache_sysroot_path/usr/include/stdint.h" ] && [ -L "$v8_sysroot_path" ]; then
        local link_target
        link_target=$(readlink "$v8_sysroot_path")
        if [ "$link_target" = "$cache_sysroot_path" ]; then
            echo -e "${BLUE}${label} sysroot 已就绪: $cache_sysroot_path${NC}"
            return 0
        fi
    fi

    echo "=== 处理 ${label} sysroot ==="
    echo -e "缓存路径: ${BLUE}${cache_sysroot_path}${NC}"

    mkdir -p "$cache_sysroot_path"

    # 处理 V8 树内的旧实体目录：迁移到缓存（避免重复下载）
    # link_sysroot 内部：如果是实体目录且缓存为空 → mv 到缓存；如果缓存已有数据 → 删除旧目录
    link_sysroot "$v8_sysroot_path" "$cache_sysroot_path"

    # 缓存不完整时，下载 sysroot
    # 此时 v8_sysroot_path 已是符号链接，install-sysroot.py 的 rmtree 会跟随链接删缓存，
    # 所以必须先移除符号链接，让 install-sysroot.py 直接操作缓存目录
    if [ ! -f "$cache_sysroot_path/usr/include/stdint.h" ]; then
        # 移除符号链接，避免 install-sysroot.py 的 rmtree 跟随链接删除缓存内容
        [ -L "$v8_sysroot_path" ] && rm -f "$v8_sysroot_path"

        ( cd "$V8_SRC_DIR" && python3 ./build/linux/sysroot_scripts/install-sysroot.py --arch="$arch" )
        if [ $? -ne 0 ]; then
            echo "错误: ${label} sysroot 下载失败"
            return 1
        fi

        # install-sysroot.py 可能将缓存目录替换为实体目录（rmtree + mkdir），
        # 如果 V8 树内路径现在是实体目录而非符号链接，把它移到缓存并重建链接
        if [ -d "$v8_sysroot_path" ] && [ ! -L "$v8_sysroot_path" ]; then
            rm -rf "$cache_sysroot_path"
            mv "$v8_sysroot_path" "$cache_sysroot_path"
            _create_relative_symlink "$cache_sysroot_path" "$v8_sysroot_path"
        fi
    else
        # 缓存已完整，确保符号链接存在
        if [ ! -L "$v8_sysroot_path" ]; then
            _create_relative_symlink "$cache_sysroot_path" "$v8_sysroot_path"
        fi
    fi

    echo "=== ${label} sysroot 处理完成 ==="
    echo ""
}

download_sysroot() {
    # V8 树内的期望路径（install-sysroot.py 的安装目标）
    local V8_LINUX_DIR="${V8_SRC_DIR}/build/linux"
    local V8_ARM64_SYSROOT="${V8_LINUX_DIR}/debian_bullseye_arm64-sysroot"
    local V8_AMD64_SYSROOT="${V8_LINUX_DIR}/debian_bullseye_amd64-sysroot"

    # 前置检查：sysroot 需要在 V8 源码树内创建符号链接，V8 目录必须存在
    if [ ! -d "$V8_LINUX_DIR" ]; then
        echo "错误: V8 源码目录不存在: $V8_LINUX_DIR"
        echo "请先运行 cargo vendor 下载依赖，或去掉 --skip-vendor 参数"
        return 1
    fi

    # --force 清理：同时删除缓存和 V8 树内的符号链接
    if [[ "$BD_FORCE" == "1" ]]; then
        if [[ -d "$SYSROOT_CACHE_DIR" ]]; then
            echo "=== [--force] 删除 sysroot 缓存: $SYSROOT_CACHE_DIR ==="
            rm -rf "$SYSROOT_CACHE_DIR"
        fi
        # 清理 V8 树内残留的符号链接或目录
        [ -e "$V8_ARM64_SYSROOT" ] || [ -L "$V8_ARM64_SYSROOT" ] && rm -rf "$V8_ARM64_SYSROOT"
        [ -e "$V8_AMD64_SYSROOT" ] || [ -L "$V8_AMD64_SYSROOT" ] && rm -rf "$V8_AMD64_SYSROOT"
    fi

    mkdir -p "$SYSROOT_CACHE_DIR"

    # 下载 ARM64 sysroot（TARGET v8 构建使用）
    ensure_sysroot "arm64" "$V8_ARM64_SYSROOT" "$SYSROOT_CACHE_DIR/debian_bullseye_arm64-sysroot" || return 1

    # 下载 AMD64 sysroot（HOST v8 构建使用：obscura-js 的 build-dependencies 会触发 x86_64 的 v8 编译）
    # 必须在此处预下载，否则 cargo 并行构建时 HOST v8 先于 TARGET v8 运行，找不到 glib-2.0 导致 gn gen 失败
    ensure_sysroot "amd64" "$V8_AMD64_SYSROOT" "$SYSROOT_CACHE_DIR/debian_bullseye_amd64-sysroot" || return 1
}

create_cargo_configs() {
    echo "=== 创建 cargo 配置文件 ==="

    # 创建镜像配置（用于 vendor 阶段）
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

    # 创建 vendor 配置（用于编译阶段）
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
    echo "=== cargo vendor (使用国内镜像) ==="
    cp "$CARGO_CONFIG_VENDOR" "$CARGO_CONFIG"
    echo "cargo vendor --versioned-dirs third_party --locked"
    cargo vendor --versioned-dirs third_party --locked
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "cargo vendor 失败，退出码: $exit_code"
        cp "$CARGO_CONFIG_BUILD" "$CARGO_CONFIG"
        return $exit_code
    fi
    echo "=== cargo vendor 完成 ==="
}

# ===================== 帮助信息 =====================

bd_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "下载 Obscura 交叉编译（x86_64 → aarch64）所需的全部依赖。"
    echo ""
    echo "选项:"
    echo "  --skip-clang       跳过 clang 下载"
    echo "  --skip-ninja-gn    跳过 ninja/gn 下载"
    echo "  --skip-libclang    跳过 libclang.so 下载"
    echo "  --skip-sysroot     跳过 ARM64 sysroot 下载"
    echo "  --skip-cmake       跳过 cmake 下载（--features stealth 需要）"
    echo "  --skip-vendor      跳过 cargo vendor"
    echo "  --vendor-only      只执行 cargo vendor（跳过其他所有下载）"
    echo "  --force            强制重新下载已存在的文件"
    echo "  -h, --help         显示帮助"
    echo ""
    echo "示例:"
    echo "  $0                         # 下载全部内容"
    echo "  $0 --vendor-only           # 只执行 cargo vendor"
    echo "  $0 --skip-vendor           # 下载 clang/ninja_gn/libclang/sysroot，不 vendor"
    echo "  $0 --skip-ninja-gn         # 下载 clang/libclang/sysroot，跳过 ninja/gn"
    echo "  $0 --force --skip-vendor   # 强制重新下载 clang/libclang/sysroot"
    echo ""
    echo "被其他脚本引用:"
    echo "  source ./_scripts/build_download.sh  # 获取变量和函数，不执行下载"
    exit 0
}

# ===================== 独立执行逻辑 =====================
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
                echo "未知选项: $1"
                bd_usage
                ;;
        esac
    done

    echo "=== build_download.sh 开始: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
    echo "  FORCE=$BD_FORCE  VENDOR_ONLY=$BD_VENDOR_ONLY"
    echo ""

    cd "$OBSCURA_DIR"

    if [[ "$BD_VENDOR_ONLY" == "1" ]]; then
        create_cargo_configs
        run_vendor || exit 1
    else
        [[ "$BD_SKIP_CLANG"    -eq 0 ]] && download_clang       || echo ">>> 跳过 clang 下载"
        [[ "$BD_SKIP_NINJA_GN" -eq 0 ]] && download_ninja_gn    || echo ">>> 跳过 ninja/gn 下载"
        [[ "$BD_SKIP_LIBCLANG" -eq 0 ]] && download_libclang    || echo ">>> 跳过 libclang 下载"
        # cargo vendor 必须在 sysroot 之前运行：sysroot 需要在 V8 源码树内创建符号链接
        if [[ "$BD_SKIP_VENDOR" -eq 0 ]]; then
            create_cargo_configs
            run_vendor || exit 1
        else
            echo ">>> 跳过 cargo vendor"
        fi
        [[ "$BD_SKIP_SYSROOT"  -eq 0 ]] && download_sysroot     || echo ">>> 跳过 sysroot 下载"
        [[ "$BD_SKIP_CMAKE"   -eq 0 ]] && download_cmake        || echo ">>> 跳过 cmake 下载"
    fi

    echo ""
    echo "=== build_download.sh 完成: $(date "+%Y-%m-%d %H:%M:%S.%N" | cut -b1-23) ==="
fi
