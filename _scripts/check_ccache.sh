#!/bin/bash
# check_ccache.sh - 检查、安装并配置 ccache
# 用于加速 V8 和 C/C++ 编译
#
# 用法：在 build.sh 中 source 此脚本
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/check_ccache.sh"
#
# 成功后会导出以下环境变量：
#   CCACHE_ENABLED=1
#   CCACHE_DIR
#   CCACHE_MAXSIZE
#   CC (如果未设置)
#   CXX (如果未设置)

[[ -n "$_CCACHE_CHECK_LOADED" ]] && return 0 2>/dev/null
_CCACHE_CHECK_LOADED=1

# 解析项目根目录（realpath 跨平台处理软链接）
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# 检测运行环境
detect_environment() {
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "mingw64"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            echo "ubuntu"
        else
            echo "linux"
        fi
    else
        echo "unknown"
    fi
}

# 检查 ccache 是否已安装（系统或 _deps/ccache）
check_ccache_installed() {
    # 先检查系统 PATH
    if command -v ccache &> /dev/null; then
        return 0
    fi
    # 再检查 _deps/ccache/bin/ccache
    if [[ -x "${OBSCURA_DIR}/_deps/ccache/bin/ccache" ]]; then
        return 0
    fi
    return 1
}

# 从 Ubuntu 官方镜像下载 ccache 到 _deps/ccache/
install_ccache_ubuntu() {
    echo -e "${BLUE}=== 从 Ubuntu 镜像下载 ccache 到 _deps/ccache/ ===${NC}"

    local DEPS_DIR="${OBSCURA_DIR}/_deps"
    local CCACHE_DEPS_DIR="${DEPS_DIR}/ccache"
    # ccache 3.7.7 依赖简单（libc6 + zlib），系统上都已满足，无需额外下载
    local CCACHE_DEB_URL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/c/ccache/ccache_3.7.7-1_amd64.deb"
    local CCACHE_DEB="/tmp/ccache_3.7.7-1_amd64.deb"

    # 下载 ccache .deb 包
    echo -e "${BLUE}下载: ${CCACHE_DEB_URL}${NC}"
    wget -q -O "$CCACHE_DEB" "$CCACHE_DEB_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: 下载 ccache 失败${NC}"
        rm -f "$CCACHE_DEB"
        return 1
    fi

    # 提取到 _deps/ccache/
    echo -e "${BLUE}提取到: ${CCACHE_DEPS_DIR}${NC}"
    mkdir -p "${CCACHE_DEPS_DIR}"
    dpkg-deb -x "$CCACHE_DEB" "${CCACHE_DEPS_DIR}"
    rm -f "$CCACHE_DEB"

    # 删除不需要的目录（文档、手册页等）
    rm -rf "${CCACHE_DEPS_DIR}/usr/share"

    # 创建 bin 目录并链接 ccache 二进制
    mkdir -p "${CCACHE_DEPS_DIR}/bin"
    ln -sf "${CCACHE_DEPS_DIR}/usr/bin/ccache" "${CCACHE_DEPS_DIR}/bin/ccache"

    # 验证提取成功
    if [[ ! -x "${CCACHE_DEPS_DIR}/bin/ccache" ]]; then
        echo -e "${RED}错误: ccache 提取失败${NC}"
        return 1
    fi

    # 将 _deps/ccache/bin 添加到 PATH
    export PATH="${CCACHE_DEPS_DIR}/bin:${PATH}"

    echo -e "${GREEN}=== ccache 3.7.7 下载完成 ===${NC}"
    echo -e "  路径: ${BLUE}$(command -v ccache)${NC}"
    echo -e "  版本: $(ccache --version | head -n1)"
    return 0
}

# 在 MSYS2/MinGW64 上安装 ccache
install_ccache_mingw64() {
    echo -e "${BLUE}=== 尝试在 MSYS2/MinGW64 上安装 ccache ===${NC}"

    if ! command -v pacman &> /dev/null; then
        echo -e "${RED}错误: 未找到 pacman${NC}"
        return 1
    fi

    # MSYS2 环境
    if [[ "$OSTYPE" == "msys" ]]; then
        echo -e "${BLUE}执行: pacman -S --noconfirm ccache${NC}"
        pacman -S --noconfirm ccache
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: ccache 安装失败${NC}"
            return 1
        fi
    # MinGW64 环境
    elif [[ "$OSTYPE" == "cygwin" && "$MSYSTEM" == "MINGW64" ]]; then
        echo -e "${BLUE}执行: pacman -S --noconfirm mingw-w64-x86_64-ccache${NC}"
        pacman -S --noconfirm mingw-w64-x86_64-ccache
        if [ $? -ne 0 ]; then
            echo -e "${RED}错误: ccache 安装失败${NC}"
            return 1
        fi
    else
        echo -e "${RED}错误: 不支持的 MSYS2 环境: OSTYPE=$OSTYPE, MSYSTEM=$MSYSTEM${NC}"
        return 1
    fi

    echo -e "${GREEN}=== ccache 安装成功 ===${NC}"
    return 0
}

# 配置 ccache
configure_ccache() {
    local obscura_dir="$1"

    # 设置缓存目录（在项目根目录下）
    export CCACHE_DIR="${obscura_dir}/.ccache"
    export CCACHE_MAXSIZE="50G"  # 50GB 缓存

    # 创建缓存目录
    mkdir -p "${CCACHE_DIR}"

    # 启用压缩（节省空间）
    export CCACHE_COMPRESS="1"
    export CCACHE_COMPRESSLEVEL="6"

    # 其他优化选项
    export CCACHE_SLOPPINESS="include_file_mtime,time_macros"
    export CCACHE_CPP2="1"  # 使用 -cpp2 模式，提高命中率

    echo -e "${GREEN}=== ccache 配置完成 ===${NC}"
    echo -e "  缓存目录: ${BLUE}${CCACHE_DIR}${NC}"
    echo -e "  最大容量: ${BLUE}${CCACHE_MAXSIZE}${NC}"
    echo -e "  压缩: ${BLUE}启用 (level ${CCACHE_COMPRESSLEVEL})${NC}"

    # 显示当前缓存统计
    if check_ccache_installed; then
        echo ""
        echo -e "${BLUE}当前 ccache 统计:${NC}"
        ccache -s 2>/dev/null || true
    fi
}

# 设置编译器包装
setup_compiler_wrapper() {
    # 如果 CC/CXX 已设置，包装它们；否则使用默认的 clang/gcc
    if [[ -n "$CC" ]]; then
        # CC 已设置，包装为 ccache
        if [[ "$CC" != ccache* ]]; then
            export CC="ccache $CC"
        fi
    else
        # CC 未设置，使用默认的 clang/gcc
        if command -v clang &> /dev/null; then
            export CC="ccache clang"
        elif command -v gcc &> /dev/null; then
            export CC="ccache gcc"
        fi
    fi

    if [[ -n "$CXX" ]]; then
        # CXX 已设置，包装为 ccache
        if [[ "$CXX" != ccache* ]]; then
            export CXX="ccache $CXX"
        fi
    else
        # CXX 未设置，使用默认的 clang++/g++
        if command -v clang++ &> /dev/null; then
            export CXX="ccache clang++"
        elif command -v g++ &> /dev/null; then
            export CXX="ccache g++"
        fi
    fi

    # 导出标志表示 ccache 已启用
    export CCACHE_ENABLED=1

    echo -e "${GREEN}=== 编译器包装设置完成 ===${NC}"
    [[ -n "$CC" ]] && echo -e "  CC=${BLUE}${CC}${NC}"
    [[ -n "$CXX" ]] && echo -e "  CXX=${BLUE}${CXX}${NC}"
}

# 主函数
main() {
    # OBSCURA_DIR 已通过 realpath 在脚本顶部解析（处理软链接）
    local obscura_dir="$OBSCURA_DIR"
    local env=$(detect_environment)

    echo -e "${BLUE}=== ccache 检查与配置 ===${NC}"
    echo -e "检测到环境: ${BLUE}${env}${NC}"

    # 检查是否已安装
    if check_ccache_installed; then
        # 如果 ccache 在 _deps/ccache/ 中（不在系统 PATH），确保 PATH 已更新
        if ! command -v ccache &> /dev/null && [[ -x "${obscura_dir}/_deps/ccache/bin/ccache" ]]; then
            export PATH="${obscura_dir}/_deps/ccache/bin:${PATH}"
        fi
        echo -e "${GREEN}✓ ccache 已安装${NC}"
        echo -e "  版本: $(ccache --version | head -n1)"
        echo -e "  路径: $(command -v ccache)"
    else
        echo -e "${YELLOW}✗ ccache 未安装${NC}"

        # 尝试安装
        case "$env" in
            ubuntu|debian)
                install_ccache_ubuntu
                if [ $? -ne 0 ]; then
                    echo ""
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${RED}错误: ccache 安装失败${NC}"
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${YELLOW}请手动安装:${NC}"
                    echo -e "  ${BLUE}sudo apt-get install ccache${NC}"
                    echo ""
                    echo -e "${YELLOW}不使用 ccache 继续构建（编译速度较慢）...${NC}"
                    export CCACHE_ENABLED=0
                    return 0
                fi
                ;;
            mingw64)
                install_ccache_mingw64
                if [ $? -ne 0 ]; then
                    echo ""
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${RED}错误: ccache 安装失败${NC}"
                    echo -e "${RED}=========================================${NC}"
                    echo -e "${YELLOW}请手动安装:${NC}"
                    echo -e "  ${BLUE}MSYS2 环境: pacman -S ccache${NC}"
                    echo -e "  ${BLUE}MinGW64 环境: pacman -S mingw-w64-x86_64-ccache${NC}"
                    echo ""
                    echo -e "${YELLOW}不使用 ccache 继续构建（编译速度较慢）...${NC}"
                    export CCACHE_ENABLED=0
                    return 0
                fi
                ;;
            *)
                echo ""
                echo -e "${RED}=========================================${NC}"
                echo -e "${RED}错误: 不支持的环境或缺少 ccache${NC}"
                echo -e "${RED}=========================================${NC}"
                echo -e "${YELLOW}请手动安装 ccache:${NC}"
                echo -e "  ${BLUE}Ubuntu/Debian: sudo apt-get install ccache${NC}"
                echo -e "  ${BLUE}MSYS2: pacman -S ccache${NC}"
                echo -e "  ${BLUE}MinGW64: pacman -S mingw-w64-x86_64-ccache${NC}"
                echo ""
                echo -e "${YELLOW}不使用 ccache 继续构建（编译速度较慢）...${NC}"
                export CCACHE_ENABLED=0
                return 0
                ;;
        esac

        # 再次检查是否安装成功
        if ! check_ccache_installed; then
            echo -e "${RED}错误: ccache 安装后仍无法找到${NC}"
            export CCACHE_ENABLED=0
            return 0
        fi
    fi

    # 配置 ccache
    configure_ccache "$obscura_dir"

    # 设置编译器包装
    setup_compiler_wrapper

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}✓ ccache 已启用，将显著加速编译${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
}

# 执行主函数
main "$@"
