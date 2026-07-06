#!/bin/bash
# ============================================================
# prepare_playwright.sh - 解压 Playwright 源码包并设置 playwright-core 链接
#
# 用法:
#   ./sdk/obscura_ts/prepare_playwright.sh
#   ./sdk/obscura_ts/prepare_playwright.sh --version 1.60.0
#   ./sdk/obscura_ts/prepare_playwright.sh --force
#
# 此脚本会：
#   1. 检查 _deps/playwright/v<version>.tar.gz 是否存在
#   2. 如果不存在，调用 _scripts/download_playwright.sh 下载
#   3. 解压到 _deps/playwright/extracted/
#   4. 创建 _deps/playwright/playwright-core 符号链接
# ============================================================

set -euo pipefail

# ===================== 常量定义 =====================
# 解析项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBSCURA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PLAYWRIGHT_DIR="${OBSCURA_DIR}/_deps/playwright"
EXTRACTED_DIR="${PLAYWRIGHT_DIR}/extracted"
SYMLINK_PATH="${PLAYWRIGHT_DIR}/playwright-core"

# 默认版本
DEFAULT_PLAYWRIGHT_VERSION="1.60.0"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# ===================== 参数解析 =====================
PLAYWRIGHT_VERSION="$DEFAULT_PLAYWRIGHT_VERSION"
FORCE_EXTRACT=0

show_help() {
    echo "用法: $0 [选项]"
    echo ""
    echo "解压 Playwright 源码包并设置 playwright-core 链接"
    echo ""
    echo "选项:"
    echo "  --version <version>   指定 Playwright 版本 (默认: ${DEFAULT_PLAYWRIGHT_VERSION})"
    echo "  --force               强制重新解压"
    echo "  -h, --help            显示帮助"
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
            FORCE_EXTRACT=1
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

# ===================== 主流程 =====================

main() {
    log_info "Playwright 准备工具"
    log_info "版本: v${PLAYWRIGHT_VERSION}"
    log_info "Playwright 目录: ${PLAYWRIGHT_DIR}"

    local tarball_path="${PLAYWRIGHT_DIR}/v${PLAYWRIGHT_VERSION}.tar.gz"

    # 检查 tarball 是否存在
    if [[ ! -f "$tarball_path" ]]; then
        log_info "Playwright v${PLAYWRIGHT_VERSION} 不存在，调用下载脚本..."
        "${OBSCURA_DIR}/_scripts/download_playwright.sh" --version "$PLAYWRIGHT_VERSION"

        if [[ ! -f "$tarball_path" ]]; then
            log_error "下载后仍未找到 tarball: ${tarball_path}"
            exit 1
        fi
    fi

    log_info "找到 tarball: ${tarball_path}"

    # 检查是否需要重新解压
    local inner_dir="${EXTRACTED_DIR}/playwright-${PLAYWRIGHT_VERSION}"
    local playwright_core_dir="${inner_dir}/packages/playwright-core"

    if [[ -d "$inner_dir" ]] && [[ "$FORCE_EXTRACT" -eq 0 ]]; then
        log_info "已解压: ${inner_dir}"
    else
        if [[ "$FORCE_EXTRACT" -eq 1 ]] && [[ -d "$EXTRACTED_DIR" ]]; then
            log_info "强制重新解压，清理旧目录..."
            rm -rf "$EXTRACTED_DIR"
        fi

        log_info "解压 Playwright 源码包..."
        mkdir -p "$EXTRACTED_DIR"

        if ! tar -xzf "$tarball_path" -C "$EXTRACTED_DIR"; then
            log_error "解压失败: ${tarball_path}"
            exit 1
        fi

        log_info "解压完成: ${inner_dir}"
    fi

    # 验证 playwright-core 目录
    if [[ ! -d "$playwright_core_dir" ]]; then
        log_error "未找到 playwright-core: ${playwright_core_dir}"
        log_error "请确认 Playwright 版本 v${PLAYWRIGHT_VERSION} 的源码结构正确"
        exit 1
    fi

    log_info "找到 playwright-core: ${playwright_core_dir}"

    # 创建符号链接
    if [[ -L "$SYMLINK_PATH" ]] || [[ -e "$SYMLINK_PATH" ]]; then
        local current_target
        current_target=$(readlink "$SYMLINK_PATH" 2>/dev/null || echo "")
        if [[ "$current_target" == "$playwright_core_dir" ]]; then
            log_info "符号链接已正确: ${SYMLINK_PATH} -> ${playwright_core_dir}"
        else
            log_info "更新符号链接: ${SYMLINK_PATH}"
            rm -f "$SYMLINK_PATH"
            ln -sf "$playwright_core_dir" "$SYMLINK_PATH"
        fi
    else
        log_info "创建符号链接: ${SYMLINK_PATH} -> ${playwright_core_dir}"
        ln -sf "$playwright_core_dir" "$SYMLINK_PATH"
    fi

    # 验证 package.json
    local core_package_json="${SYMLINK_PATH}/package.json"
    if [[ ! -f "$core_package_json" ]]; then
        log_warn "playwright-core 缺少 package.json: ${core_package_json}"
        log_warn "npm install 可能会失败"
    else
        log_info "playwright-core package.json 已就绪"
    fi

    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Playwright v${PLAYWRIGHT_VERSION} 准备完成！"
    log_info ""
    log_info "下一步:"
    log_info "  cd sdk/obscura_ts && npm install"
    log_info "═══════════════════════════════════════════════════════════"
}

main
