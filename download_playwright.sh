#!/bin/bash
# ============================================================
# download_playwright.sh - 下载 Playwright 源码包到 _deps/playwright/
#
# 用法:
#   ./_scripts/download_playwright.sh                    # 下载默认版本 (v1.60.0)
#   ./_scripts/download_playwright.sh --version 1.61.0   # 下载指定版本
#   ./_scripts/download_playwright.sh --force             # 强制重新下载
#   ./_scripts/download_playwright.sh --check-only        # 仅检查更新，不下载
#
# 选项:
#   --version <version>   指定 Playwright 版本 (如 1.60.0, 1.61.0)
#   --force               强制重新下载已存在的文件
#   --check-only          仅检查是否有更新版本，不执行下载
#   -h, --help            显示帮助
# ============================================================

set -euo pipefail

# ===================== 常量定义 =====================
# 解析项目根目录
OBSCURA_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")/.." && pwd -P)"

# Playwright 依赖目录
PLAYWRIGHT_DIR="${OBSCURA_DIR}/_deps/playwright"

# 默认版本
DEFAULT_PLAYWRIGHT_VERSION="1.60.0"

# GitHub API URL
GITHUB_API_URL="https://api.github.com/repos/microsoft/playwright/releases/latest"

# 下载超时 (秒)
API_TIMEOUT=10
DOWNLOAD_TIMEOUT=300

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# ===================== 参数解析 =====================
PLAYWRIGHT_VERSION="$DEFAULT_PLAYWRIGHT_VERSION"
FORCE_DOWNLOAD=0
CHECK_ONLY=0

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "下载 Playwright 源码包到 _deps/playwright/"
    echo ""
    echo "选项:"
    echo "  --version <version>   指定 Playwright 版本 (如 1.60.0, 1.61.0)"
    echo "  --force               强制重新下载已存在的文件"
    echo "  --check-only          仅检查是否有更新版本，不执行下载"
    echo "  -h, --help            显示帮助"
    echo ""
    echo "示例:"
    echo "  $0                           # 下载默认版本 v${DEFAULT_PLAYWRIGHT_VERSION}"
    echo "  $0 --version 1.61.0          # 下载 v1.61.0"
    echo "  $0 --force                   # 强制重新下载"
    echo "  $0 --check-only              # 仅检查更新"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}错误: --version 需要指定版本号${NC}" >&2
                exit 1
            fi
            PLAYWRIGHT_VERSION="$2"
            shift 2
            ;;
        --force)
            FORCE_DOWNLOAD=1
            shift
            ;;
        --check-only)
            CHECK_ONLY=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}错误: 未知参数 '$1'${NC}" >&2
            show_help
            exit 1
            ;;
    esac
done

# ===================== 工具函数 =====================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# 比较版本号: 返回 0 如果 $1 > $2, 1 如果 $1 == $2, 2 如果 $1 < $2
compare_versions() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 1
    fi

    local IFS='.'
    read -ra V1_PARTS <<< "$v1"
    read -ra V2_PARTS <<< "$v2"

    local max_len=${#V1_PARTS[@]}
    if [[ ${#V2_PARTS[@]} -gt $max_len ]]; then
        max_len=${#V2_PARTS[@]}
    fi

    for ((i = 0; i < max_len; i++)); do
        local p1=${V1_PARTS[i]:-0}
        local p2=${V2_PARTS[i]:-0}

        if ((p1 > p2)); then
            return 0
        elif ((p1 < p2)); then
            return 2
        fi
    done

    return 1
}

# 从 GitHub API 获取最新稳定版本号
get_latest_version() {
    local response
    local tag_name

    # 使用 curl 查询 GitHub API，设置超时
    if ! response=$(curl -s -m "$API_TIMEOUT" \
        -H "Accept: application/vnd.github.v3+json" \
        "$GITHUB_API_URL" 2>/dev/null); then
        return 1
    fi

    # 解析 tag_name (格式: "tag_name": "v1.61.0")
    tag_name=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"v\{0,1\}\([^"]*\)".*/\1/')

    if [[ -z "$tag_name" ]]; then
        return 1
    fi

    echo "$tag_name"
    return 0
}

# 检查是否有更新版本
check_for_updates() {
    local current_version="$1"
    local latest_version

    log_info "检查 Playwright 更新 (当前版本: v${current_version})..."

    if ! latest_version=$(get_latest_version); then
        log_warn "检查更新超时或失败，使用本地缓存版本"
        return 0
    fi

    if [[ -z "$latest_version" ]]; then
        log_warn "无法解析最新版本信息"
        return 0
    fi

    # 比较版本
    compare_versions "$latest_version" "$current_version"
    local cmp_result=$?

    if [[ $cmp_result -eq 0 ]]; then
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info "发现较新稳定版本: v${latest_version} (当前: v${current_version})"
        log_info "更新命令: $0 --version ${latest_version}"
        log_info "═══════════════════════════════════════════════════════════"
        echo ""
        return 0
    else
        log_info "当前版本 v${current_version} 已是最新稳定版本"
        return 0
    fi
}

# 下载 Playwright 源码包
download_playwright() {
    local version="$1"
    local target_file="${PLAYWRIGHT_DIR}/v${version}.tar.gz"
    local download_url="https://github.com/microsoft/playwright/archive/refs/tags/v${version}.tar.gz"

    # 创建目录
    mkdir -p "$PLAYWRIGHT_DIR"

    # 检查文件是否存在
    if [[ -f "$target_file" ]] && [[ "$FORCE_DOWNLOAD" -eq 0 ]]; then
        log_info "Playwright v${version} 已存在: ${target_file}"
        return 0
    fi

    if [[ "$FORCE_DOWNLOAD" -eq 1 ]] && [[ -f "$target_file" ]]; then
        log_info "强制重新下载，删除旧文件: ${target_file}"
        rm -f "$target_file"
    fi

    log_info "下载 Playwright v${version}..."
    log_info "URL: ${download_url}"
    log_info "目标: ${target_file}"

    if ! curl -L -m "$DOWNLOAD_TIMEOUT" \
        -o "$target_file" \
        --progress-bar \
        "$download_url"; then
        log_error "下载失败"
        rm -f "$target_file"
        return 1
    fi

    # 验证下载
    if [[ ! -f "$target_file" ]] || [[ ! -s "$target_file" ]]; then
        log_error "下载的文件为空或不存在"
        rm -f "$target_file"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "$target_file" 2>/dev/null || stat -f%z "$target_file" 2>/dev/null || echo "unknown")
    log_info "下载完成: ${target_file} (${file_size} bytes)"

    return 0
}

# ===================== 主流程 =====================

main() {
    log_info "Playwright 依赖管理工具"
    log_info "项目目录: ${OBSCURA_DIR}"
    log_info "Playwright 目录: ${PLAYWRIGHT_DIR}"

    local target_file="${PLAYWRIGHT_DIR}/v${PLAYWRIGHT_VERSION}.tar.gz"

    # 检查文件是否存在
    if [[ -f "$target_file" ]]; then
        log_info "Playwright v${PLAYWRIGHT_VERSION} 已存在: ${target_file}"

        # 检查更新
        check_for_updates "$PLAYWRIGHT_VERSION"

        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            log_info "仅检查模式，退出"
            return 0
        fi

        if [[ "$FORCE_DOWNLOAD" -eq 0 ]]; then
            log_info "使用现有文件。使用 --force 强制重新下载"
            return 0
        fi
    else
        if [[ "$CHECK_ONLY" -eq 1 ]]; then
            log_warn "本地无 Playwright v${PLAYWRIGHT_VERSION}，但处于仅检查模式"
            # 仍然检查更新
            check_for_updates "$PLAYWRIGHT_VERSION"
            return 0
        fi

        log_info "Playwright v${PLAYWRIGHT_VERSION} 不存在，开始下载..."
    fi

    # 下载
    if ! download_playwright "$PLAYWRIGHT_VERSION"; then
        log_error "下载失败，请检查网络连接"
        exit 1
    fi

    log_info "Playwright v${PLAYWRIGHT_VERSION} 准备就绪"
    log_info "下一步: 运行 sdk/obscura_ts/prepare_playwright.sh 解压并配置"
}

main
